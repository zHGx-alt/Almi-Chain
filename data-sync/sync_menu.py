#!/usr/bin/env python3
"""
Sync the menu from the chain's own database (almi_chain) to the Odoo POS (standard library only).

Reads the dish table from almi_chain and writes it to Odoo through its XML-RPC API.
almi_chain is the source of truth: when a price changes there, the next run changes it in
the POS too. Each Odoo product is linked to its dish by the internal reference
ALMI-<dish_id>, so the script can run any number of times without creating duplicates.
The first time, a product with the same name and no reference is linked instead of duplicated.

Usage:
  read -rs ODOO_PASSWORD && export ODOO_PASSWORD
  python3 sync_menu.py --dry-run     (only says what it would do, changes nothing)
  python3 sync_menu.py               (syncs)

Environment (with defaults):
  ODOO_URL=http://localhost:8069  ODOO_DB=shop  ODOO_USER=manager  ODOO_PASSWORD (required)
  ALMI_PSQL="psql -U reporting -d almi_chain"
    The read uses the reporting account (read_role): it cannot change anything.
"""
import csv
import io
import os
import shlex
import subprocess
import sys
import xmlrpc.client

URL = os.environ.get("ODOO_URL", "http://localhost:8069")
DB = os.environ.get("ODOO_DB", "shop")
USER = os.environ.get("ODOO_USER", "manager")
PSQL = os.environ.get("ALMI_PSQL", "psql -U reporting -d almi_chain")
DRY_RUN = "--dry-run" in sys.argv[1:]

# almi_chain category (CHECK on dish.category) -> POS category in Odoo
CATEGORIES = {"starter": "Starters", "main": "Mains", "dessert": "Desserts", "drink": "Drinks"}

QUERY = """
SELECT dish_id, name, coalesce(description, '') AS description, category, price, vat_rate
FROM dish ORDER BY dish_id
"""


def read_almi_chain():
    """Returns the dishes. Uses psql in CSV mode so no database driver is needed."""
    command = shlex.split(PSQL) + ["--csv", "-v", "ON_ERROR_STOP=1", "-c", QUERY]
    env = {**os.environ, "PGCLIENTENCODING": "UTF8"}  # names like "Caña" must match Odoo's exactly
    r = subprocess.run(command, capture_output=True, text=True, encoding="utf-8", env=env,
                       stdin=subprocess.DEVNULL, timeout=60)
    if r.returncode != 0:
        sys.exit(f"Could not read almi_chain:\n{r.stderr.strip()}")
    dishes = list(csv.DictReader(io.StringIO(r.stdout)))
    if not dishes:
        sys.exit("almi_chain has no dishes: has 06-sample-data.sql been loaded?")
    return dishes


def customer_price(dish):
    """almi_chain stores the price before VAT; the POS shows it with VAT included."""
    return round(float(dish["price"]) * (1 + float(dish["vat_rate"]) / 100), 2)


dishes = read_almi_chain()
print(f"almi_chain: {len(dishes)} dishes read with the read-only account.")

PASSWORD = os.environ.get("ODOO_PASSWORD") or sys.exit("ODOO_PASSWORD is not set")
uid = xmlrpc.client.ServerProxy(f"{URL}/xmlrpc/2/common").authenticate(DB, USER, PASSWORD, {})
if not uid:
    sys.exit(f"Could not log in to Odoo as {USER}")
obj = xmlrpc.client.ServerProxy(f"{URL}/xmlrpc/2/object", allow_none=True)


def x(model, method, *a, **kw):
    return obj.execute_kw(DB, uid, PASSWORD, model, method, list(a), kw)


def vat_included(rate):
    """A sales tax with the price including VAT, e.g. '10% VAT incl.'; created once from the base tax."""
    name = f"{rate}% VAT incl."
    ids = x("account.tax", "search", [["name", "=", name]], limit=1)
    if ids or DRY_RUN:
        return ids
    base = x("account.tax", "search", [["type_tax_use", "=", "sale"], ["amount", "=", rate],
                                        ["amount_type", "=", "percent"]], limit=1)
    if not base:
        sys.exit(f"Odoo has no {rate} % sales VAT")
    new = x("account.tax", "copy", base[0], {"name": name, "price_include_override": "tax_included"})
    return new if isinstance(new, list) else [new]


new = updated = unchanged = 0
for d in dishes:
    ref = f"ALMI-{d['dish_id']}"
    rate = int(float(d["vat_rate"]))
    price = customer_price(d)
    category = CATEGORIES[d["category"]]

    ids = x("product.template", "search", [["default_code", "=", ref]], limit=1)
    if not ids:  # first time: look it up by name and link it
        ids = x("product.template", "search", [["name", "=", d["name"]], ["default_code", "=", False]], limit=1)

    if ids:
        current = x("product.template", "read", ids, ["default_code", "list_price", "description_sale"])[0]
        changes = {}
        if current["default_code"] != ref:
            changes["default_code"] = ref
        if round(current["list_price"], 2) != price:
            changes["list_price"] = price
        if (current["description_sale"] or "") != d["description"]:
            changes["description_sale"] = d["description"] or False
        if not changes:
            unchanged += 1
            print(f"  = {ref} {d['name']}: {price:.2f} EUR (unchanged)")
            continue
        detail = ", ".join(f"price {current['list_price']:.2f} -> {price:.2f} EUR" if k == "list_price"
                           else "linked" if k == "default_code" else "description" for k in changes)
        if not DRY_RUN:
            # Price, reference and description only: Odoo refuses category changes while a till is open
            x("product.template", "write", ids, changes)
        updated += 1
        print(f"  ~ {ref} {d['name']}: {detail}")
    else:
        if not DRY_RUN:
            cat_id = x("pos.category", "search", [["name", "=", category]], limit=1)
            cat_id = cat_id[0] if cat_id else x("pos.category", "create", {"name": category})
            x("product.template", "create", {
                "name": d["name"], "default_code": ref, "type": "consu", "list_price": price,
                "available_in_pos": True, "pos_categ_ids": [(6, 0, [cat_id])],
                "taxes_id": [(6, 0, vat_included(rate))], "description_sale": d["description"] or False})
        new += 1
        print(f"  + {ref} {d['name']}: {price:.2f} EUR in {category} (new)")

mode = " (DRY RUN, nothing changed)" if DRY_RUN else ""
print(f"\nSync{mode}: {new} new, {updated} updated, {unchanged} unchanged.")
