#!/usr/bin/env python3
"""
Import and export Odoo data through its XML-RPC API (standard library only).

  import <menu.csv>    Loads or updates the POS menu (categories and products with their price).
                       All rows are validated first: if any row is wrong, every error is listed
                       and NOTHING is imported. Repeatable: matches products by name, never
                       duplicates, and reports what it created and what it updated.
  export <folder>      Writes the menu, customers, POS orders and invoices to CSV.
                       The CSVs contain personal data: the folder must not go into Git.

Usage (as the manager account, not admin: least privilege):
  read -rs ODOO_PASSWORD && export ODOO_PASSWORD     (asked without echo or shell history)
  ODOO_URL=http://localhost:8069 ODOO_DB=shop ODOO_USER=manager \
  python3 import_export.py import menu.csv
  python3 import_export.py export exports-$(date +%Y%m%d)

The menu CSV is ";"-separated (what spreadsheet software uses in Spain) with the columns
category;product;price_incl_vat;description. The price includes the 10 % restaurant VAT.
The fake Odoo used by the demo implements the import only; export needs a real Odoo.
"""
import csv
import math
import os
import sys
import xmlrpc.client
from pathlib import Path

URL = os.environ.get("ODOO_URL", "http://localhost:8069")
DB = os.environ.get("ODOO_DB", "shop")
USER = os.environ.get("ODOO_USER", "manager")
RESTAURANT_VAT = 10
VAT_NAME = f"{RESTAURANT_VAT}% VAT incl."
COLUMNS = {"category", "product", "price_incl_vat"}


def connect():
    password = os.environ.get("ODOO_PASSWORD") or sys.exit("ODOO_PASSWORD is not set")
    uid = xmlrpc.client.ServerProxy(f"{URL}/xmlrpc/2/common").authenticate(DB, USER, password, {})
    if not uid:
        sys.exit(f"Could not log in as {USER}")
    obj = xmlrpc.client.ServerProxy(f"{URL}/xmlrpc/2/object", allow_none=True)
    return lambda model, method, *a, **kw: obj.execute_kw(DB, uid, password, model, method, list(a), kw)


def vat_included(x):
    """10 % VAT with the price including VAT (otherwise Odoo rounds and cents get lost)."""
    vat = x("account.tax", "search", [["name", "=", VAT_NAME]], limit=1)
    if vat:
        return vat
    base = x("account.tax", "search", [["type_tax_use", "=", "sale"], ["amount", "=", RESTAURANT_VAT],
                                        ["amount_type", "=", "percent"], ["tax_scope", "=", "service"]], limit=1)
    if not base:
        sys.exit(f"There is no {RESTAURANT_VAT} % sales VAT: is the Spanish chart of accounts installed?")
    new = x("account.tax", "copy", base[0], {"name": VAT_NAME, "price_include_override": "tax_included"})
    return new if isinstance(new, list) else [new]


def validate(path):
    """Returns (rows, errors). Each row is (line, category, product, price, description)."""
    with open(path, encoding="utf-8-sig", newline="") as f:
        raw = list(csv.DictReader(f, delimiter=";"))
    if not raw or not COLUMNS <= set(raw[0]):
        sys.exit(f"{path}: needs the columns {', '.join(sorted(COLUMNS))} separated by ';'")
    rows, errors = [], []
    for line, r in enumerate(raw, start=2):  # line 1 is the header
        # DictReader fills missing fields with None and puts extra ones under the None key
        if None in r or None in r.values():
            errors.append(f"line {line}: wrong number of columns")
            continue
        product, category = r["product"].strip(), r["category"].strip()
        try:
            price = float(r["price_incl_vat"].replace(",", "."))
            if not math.isfinite(price) or price < 0:
                raise ValueError
        except ValueError:
            errors.append(f"line {line}: invalid price '{r['price_incl_vat']}'")
            continue
        if not product or not category:
            errors.append(f"line {line}: missing product or category")
            continue
        rows.append((line, category, product, price, (r.get("description") or "").strip()))
    return rows, errors, len(raw)


def import_menu(path):
    rows, errors, total = validate(path)
    if errors:
        for e in errors:
            print(f"  ERROR {e}")
        print(f"\nNothing imported: {len(errors)} of {total} rows in {path} have errors. Fix them and run again.")
        return 1

    x = connect()
    vat = vat_included(x)
    categories, created, updated = {}, 0, 0
    for _line, category, product, price, description in rows:
        if category not in categories:
            ids = x("pos.category", "search", [["name", "=", category]], limit=1)
            categories[category] = ids[0] if ids else x("pos.category", "create", {"name": category})
        values = {"list_price": price, "available_in_pos": True, "taxes_id": [(6, 0, vat)],
                  "pos_categ_ids": [(6, 0, [categories[category]])],
                  "description_sale": description or False}
        existing = x("product.template", "search", [["name", "=", product]], limit=1)
        if existing:
            x("product.template", "write", existing, values)
            updated += 1
            print(f"  = {category} · {product}: {price:.2f} EUR (updated)")
        else:
            x("product.template", "create", {"name": product, "type": "consu", **values})
            created += 1
            print(f"  + {category} · {product}: {price:.2f} EUR (new)")

    print(f"\nImport: {created} new, {updated} updated, 0 with errors ({total} rows in {path}).")
    return 0


def export(folder):
    x = connect()
    target = Path(folder)
    target.mkdir(parents=True, exist_ok=True)
    company = x("res.company", "search_read", [], fields=["partner_id"], limit=1)[0]["partner_id"][0]
    # (file, model, filter, Odoo fields, CSV header)
    tables = [
        ("menu.csv", "product.template", [["available_in_pos", "=", True]],
         ["pos_categ_ids/name", "name", "list_price", "description_sale"],
         ["category", "product", "price_incl_vat", "description"]),
        ("customers.csv", "res.partner", [["user_ids", "=", False], ["id", "!=", company], ["active", "=", True]],
         ["name", "vat", "email", "phone", "city"],
         ["name", "tax_id", "email", "phone", "city"]),
        ("pos-orders.csv", "pos.order", [],
         ["name", "date_order", "config_id/name", "partner_id/name", "amount_tax", "amount_total", "state"],
         ["order", "date", "pos", "customer", "vat", "total", "state"]),
        ("invoices.csv", "account.move", [["move_type", "in", ["out_invoice", "out_refund"]], ["state", "=", "posted"]],
         ["name", "invoice_date", "partner_id/name", "amount_untaxed", "amount_tax", "amount_total", "payment_state"],
         ["invoice", "date", "customer", "tax_base", "vat", "total", "payment"]),
    ]
    for file_name, model, domain, fields, header in tables:
        ids = x(model, "search", domain, order="id")
        data = x(model, "export_data", ids, fields)["datas"] if ids else []
        # utf-8-sig and ";": opens correctly with a double click in a Spanish-locale spreadsheet
        with open(target / file_name, "w", encoding="utf-8-sig", newline="") as f:
            w = csv.writer(f, delimiter=";")
            w.writerow(header)
            w.writerows(data)
        print(f"  {file_name}: {len(data)} rows ({model})")
    print(f"\nExported to {target.resolve()}. It contains personal data: keep it out of Git and encrypted.")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 3 or sys.argv[1] not in ("import", "export"):
        sys.exit(__doc__)
    sys.exit(import_menu(sys.argv[2]) if sys.argv[1] == "import" else export(sys.argv[2]))
