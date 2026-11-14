#!/usr/bin/env python3
"""
Sample menu, dining areas and tables for the bar tills.

  - POS categories: Coffees, Drinks, Starters, Mains, Desserts
  - Products with the menu price and the 10 % restaurant VAT INCLUDED (tax "10% VAT incl.")
  - Areas "Dining room" (6 tables) and "Bar" (4 seats), on both tills
  - The tills show prices with VAT included

A SAMPLE menu to try the POS: the real menu comes from the chain's database (data-sync/).

Usage:
  read -rs ODOO_ADMIN_PASSWORD && export ODOO_ADMIN_PASSWORD
  ODOO_URL=http://localhost:8069 ODOO_DB=shop python3 load_menu_and_tables.py
Idempotent: whatever already exists (by name) is not duplicated.
"""
import os
import sys
import xmlrpc.client

URL = os.environ.get("ODOO_URL", "http://localhost:8069")
DB = os.environ.get("ODOO_DB", "shop")
ADMIN_PW = os.environ["ODOO_ADMIN_PASSWORD"]

RESTAURANT_VAT = 10  # restaurant service: reduced VAT rate
MENU = {  # category: [(product, price with VAT)]
    "Coffees": [("Café", 1.50), ("Café con leche", 1.80), ("Herbal tea", 1.60)],
    "Drinks": [("Agua mineral", 1.50), ("Soft drink", 2.50), ("Caña", 2.50), ("Glass of wine", 3.00)],
    "Starters": [("Patatas bravas", 5.50), ("Croquetas de jamón", 7.00), ("Mixed salad", 8.50)],
    "Mains": [("Menu of the day", 14.50), ("Almi burger", 12.50), ("Entrecôte", 19.00)],
    "Desserts": [("Tarta de queso", 5.00), ("Homemade flan", 4.00)],
}
AREAS = {  # area: (number of tables, first table number, seats, shape)
    "Dining room": (6, 1, 4, "square"),
    "Bar": (4, 11, 1, "round"),
}

uid = xmlrpc.client.ServerProxy(f"{URL}/xmlrpc/2/common").authenticate(DB, "admin", ADMIN_PW, {})
if not uid:
    sys.exit("Could not log in as admin")
obj = xmlrpc.client.ServerProxy(f"{URL}/xmlrpc/2/object", allow_none=True)


def x(model, method, *a, **kw):
    return obj.execute_kw(DB, uid, ADMIN_PW, model, method, list(a), kw)


tills = x("pos.config", "search", [["name", "like", "Bar POS"]])
if not tills:
    sys.exit("No bar tills found: run configure_odoo.py first")
# 10 % VAT WITH THE VAT INCLUDED in the price. If the price were stored before VAT, Odoo would round it
# to 2 decimals (2.50 / 1.10 = 2.27) and adding the VAT back loses cents: two beers came to 4.99 EUR.
VAT_NAME = f"{RESTAURANT_VAT}% VAT incl."
vat = x("account.tax", "search", [["name", "=", VAT_NAME]], limit=1)
if not vat:
    base = x("account.tax", "search", [["type_tax_use", "=", "sale"], ["amount", "=", RESTAURANT_VAT],
                                        ["amount_type", "=", "percent"], ["tax_scope", "=", "service"]], limit=1)
    new = x("account.tax", "copy", base[0], {"name": VAT_NAME, "price_include_override": "tax_included"})
    vat = new if isinstance(new, list) else [new]  # in Odoo 19, copy returns a list of ids

print("==> 1/3 Sample menu")
for i, (category, products) in enumerate(MENU.items()):
    cat = x("pos.category", "search", [["name", "=", category]])
    cat = cat[0] if cat else x("pos.category", "create", {"name": category, "sequence": i})
    for name, price in products:
        values = {"name": name, "type": "consu", "available_in_pos": True,
                  "list_price": price,  # menu price: VAT included
                  "taxes_id": [(6, 0, vat)], "pos_categ_ids": [(6, 0, [cat])]}
        existing = x("product.template", "search", [["name", "=", name]])
        if existing:  # price and tax only: with a till open Odoo refuses category or area changes
            x("product.template", "write", existing, {k: values[k] for k in ("list_price", "taxes_id")})
        else:
            x("product.template", "create", values)
        print(f"    {category} · {name}: {price:.2f} EUR ({VAT_NAME})")

print("==> 2/3 Areas and tables")
open_sessions = x("pos.session", "search_read", [["state", "!=", "closed"], ["config_id", "in", tills]], fields=["name"])
if open_sessions:
    sys.exit("    Tills are open (" + ", ".join(s["name"] for s in open_sessions) +
             "): Odoo does not allow area or till changes with a till open. Close them and run again.")
existing_floors = x("restaurant.floor", "search_read", [], fields=["name", "table_ids"], order="id")
for n, (area, (count, first, seats, shape)) in enumerate(AREAS.items()):
    floor = [f for f in existing_floors if f["name"] == area]
    if floor:
        floor_id = floor[0]["id"]
    else:
        # reuse the empty areas Odoo creates when restaurant mode is turned on
        free = [f for f in existing_floors if f["name"] not in AREAS and not f["table_ids"]]
        if free:
            floor_id = free[0]["id"]
            existing_floors.remove(free[0])
            x("restaurant.floor", "write", [floor_id], {"name": area})
        else:
            floor_id = x("restaurant.floor", "create", {"name": area})
    x("restaurant.floor", "write", [floor_id], {"sequence": n, "pos_config_ids": [(6, 0, tills)]})
    numbers = {t["table_number"] for t in x("restaurant.table", "search_read", [["floor_id", "=", floor_id]],
                                            fields=["table_number"])}
    for k in range(count):
        number = first + k
        if number in numbers:
            continue
        x("restaurant.table", "create", {
            "floor_id": floor_id, "table_number": number, "seats": seats, "shape": shape,
            "position_h": 50 + (k % 3) * 160, "position_v": 50 + (k // 3) * 160, "width": 110, "height": 110})
    print(f"    {area}: {count} tables ({first}-{first + count - 1}), on both tills")
# leftover areas (Odoo creates one per till, with 1 table and the company name): archived
for f in existing_floors:
    if f["name"] not in AREAS:
        x("restaurant.floor", "write", [f["id"]], {"active": False})

print("==> 3/3 Tills show prices with VAT included")
x("pos.config", "write", tills, {"iface_tax_included": "total"})
print("    Done")
