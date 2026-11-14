#!/usr/bin/env python3
"""
Configures Odoo for the restaurant through its XML-RPC API: no clicks, and repeatable.

  1. Company data: Almi-Chain, Spain, EUR
  2. The modules the business needs: Invoicing (+ Spanish chart of accounts), Sales, CRM
     (customers), Employees (staff), Email Marketing, Inventory, and Point of Sale in restaurant mode
  3. Two bar tills: "Bar POS 1" and "Bar POS 2"
  4. Least-privilege users: manager (everything) and cashier1/cashier2 (POS only)

Usage:
  read -rs ODOO_ADMIN_PASSWORD && export ODOO_ADMIN_PASSWORD     (asked without echo or shell history)
  ODOO_URL=http://localhost:8069 ODOO_DB=shop COMPANY="Restaurant name" python3 configure_odoo.py

New users get random passwords, written to CREDENTIALS_FILE (mode 600) and never printed.
Safe to run again: whatever already exists is not created twice.
"""
import os
import secrets
import sys
import xmlrpc.client

URL = os.environ.get("ODOO_URL", "http://localhost:8069")
DB = os.environ.get("ODOO_DB", "shop")
ADMIN_PW = os.environ["ODOO_ADMIN_PASSWORD"]
COMPANY = os.environ.get("COMPANY", "Almi-Chain")
CREDENTIALS_FILE = os.environ.get("CREDENTIALS_FILE", ".user-credentials")

# Invoices, customer relations, staff, marketing, inventory, and the bar tills
MODULES = ["account", "sale_management", "crm", "hr", "mass_mailing", "stock", "point_of_sale", "pos_restaurant"]
TILLS = ["Bar POS 1", "Bar POS 2"]
# login: (name, groups). Cashiers only get "Internal user" + "POS: user".
USERS = {
    "manager": ("Manager", ["base.group_user", "point_of_sale.group_pos_manager",
                            "sales_team.group_sale_manager", "stock.group_stock_manager",
                            "account.group_account_manager", "product.group_product_manager"]),
    "cashier1": ("Bar waiter 1", ["base.group_user", "point_of_sale.group_pos_user"]),
    "cashier2": ("Bar waiter 2", ["base.group_user", "point_of_sale.group_pos_user"]),
}


def step(text):
    print(f"\n==> {text}", flush=True)


common = xmlrpc.client.ServerProxy(f"{URL}/xmlrpc/2/common")
uid = common.authenticate(DB, "admin", ADMIN_PW, {})
if not uid:
    sys.exit("Could not log in as admin: check ODOO_ADMIN_PASSWORD")
obj = xmlrpc.client.ServerProxy(f"{URL}/xmlrpc/2/object", allow_none=True)


def x(model, method, *args, **kw):
    return obj.execute_kw(DB, uid, ADMIN_PW, model, method, list(args), kw)


def ref(xmlid):
    module, name = xmlid.split(".")
    r = x("ir.model.data", "search_read", [["module", "=", module], ["name", "=", name]],
          fields=["res_id"], limit=1)
    if not r:
        sys.exit(f"{xmlid} does not exist")
    return r[0]["res_id"]


def find_or_create(model, domain, values):
    ids = x(model, "search", domain, limit=1)
    return ids[0] if ids else x(model, "create", values)


step(f"1/4 Company: {COMPANY} (Spain, EUR)")
es = x("res.country", "search", [["code", "=", "ES"]])[0]
# EUR ships inactive: search the inactive currencies too
eur = x("res.currency", "search", [["name", "=", "EUR"]], context={"active_test": False})[0]
x("res.currency", "write", [eur], {"active": True})
x("res.company", "write", [1], {"name": COMPANY, "country_id": es, "currency_id": eur})
print("   ", x("res.company", "read", [1], fields=["name", "country_id", "currency_id"])[0])

step("2/4 Installing modules (can take a few minutes)")
for name in MODULES:
    mod = x("ir.module.module", "search_read", [["name", "=", name]], fields=["state"])[0]
    if mod["state"] == "installed":
        print(f"    {name}: already installed")
        continue
    print(f"    {name}: installing...", flush=True)
    x("ir.module.module", "button_immediate_install", [mod["id"]])
for m in x("ir.module.module", "search_read", [["name", "in", MODULES + ["l10n_es"]]], fields=["name", "state"]):
    print(f"    {m['name']}: {m['state']}")
# The warehouse takes the company name at the time Inventory was installed
# (done after installing the modules: on a new database stock.warehouse does not exist yet)
warehouses = x("stock.warehouse", "search", [])
if warehouses:
    x("stock.warehouse", "write", warehouses, {"name": COMPANY})
chart = x("res.company", "read", [1], fields=["chart_template"])[0]["chart_template"]
vat21 = x("account.tax", "search_read", [["type_tax_use", "=", "sale"], ["amount", "=", 21],
                                          ["amount_type", "=", "percent"]], fields=["name"], limit=1)
print(f"    Chart of accounts: {chart} · 21 % sales VAT: {vat21[0]['name'] if vat21 else 'NOT FOUND'}")

step("3/4 Points of sale (each till with its own cash journal; cards go to the bank)")
bank = x("account.journal", "search", [["type", "=", "bank"]], limit=1)[0]
card = find_or_create("pos.payment.method", [["name", "=", "Card"]],
                      {"name": "Card", "payment_method_type": "none", "journal_id": bank})
for n, name in enumerate(TILLS, start=1):
    till_journal = find_or_create("account.journal", [["code", "=", f"TILL{n}"]],
                                  {"name": f"Till {name}", "type": "cash", "code": f"TILL{n}"})
    cash = find_or_create("pos.payment.method", [["name", "=", f"Cash {name}"]],
                          {"name": f"Cash {name}", "payment_method_type": "none", "journal_id": till_journal})
    existing = x("pos.config", "search", [["name", "=", name]])
    if existing:
        x("pos.config", "write", existing, {"module_pos_restaurant": True})
        print(f"    {name}: ready (restaurant mode)")
    else:
        x("pos.config", "create", {"name": name, "module_pos_restaurant": True,
                                   "payment_method_ids": [(6, 0, [cash, card])]})
        print(f"    {name}: created in restaurant mode (Cash {name} + Card)")

step("4/4 Users (least privilege)")
# Nobody can sign up on their own: accounts are created by the administrator ("b2b" = invitation only).
# Installing apps such as Website switches it to "b2c" (open sign-up) and adds a link on the login page.
x("ir.config_parameter", "set_param", "auth_signup.invitation_scope", "b2b")
print("    Open user sign-up: disabled (invitation only)")
new_passwords = {}
for login, (name, groups) in USERS.items():
    group_ids = [ref(g) for g in groups]
    existing = x("res.users", "search", [["login", "=", login]])
    if existing:
        x("res.users", "write", existing, {"group_ids": [(6, 0, group_ids)]})
        print(f"    {login}: already exists (groups updated)")
        continue
    pw = secrets.token_urlsafe(12)
    x("res.users", "create", {"name": name, "login": login, "password": pw,
                              "lang": "es_ES", "tz": "Europe/Madrid",
                              "group_ids": [(6, 0, group_ids)]})
    new_passwords[login] = pw
    print(f"    {login}: created")

if new_passwords:
    fd = os.open(CREDENTIALS_FILE, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    with os.fdopen(fd, "a") as f:
        for login, pw in new_passwords.items():
            f.write(f"{login}={pw}\n")
    print(f"    New passwords saved to {CREDENTIALS_FILE} (not shown)")

print("\nDone.")
