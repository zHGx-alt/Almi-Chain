#!/usr/bin/env python3
"""
Hides from cashiers the apps they do not need to take payments.

A cashier (Internal user + POS: user) sees Contacts, Employees, Discuss, Calendar and
Dashboards by default. This script:
  1. Creates the group "Almi-Chain / Management" and adds admin and manager to it.
  2. Makes that group the ONLY one on those apps' root menus: anyone outside it does not see them.
     Odoo shows a menu if the user is in any of its groups, so adding the group is not enough
     when the menu already had "Internal user". The original groups are saved in the system
     parameter almi_chain.original_menus so the change can be undone.
The cashier then sees only Point of Sale. Hiding a menu does not remove read access to the
data (that comes from the "Internal user" access rules), but it closes the normal path to it.

Usage:
  read -rs ODOO_ADMIN_PASSWORD && export ODOO_ADMIN_PASSWORD
  ODOO_URL=http://localhost:8069 ODOO_DB=shop python3 restrict_cashier_menus.py
  ... python3 restrict_cashier_menus.py --undo      (gives the menus back their original groups)
Idempotent. Menus that do not exist in this Odoo version are skipped with a warning.
"""
import json
import os
import sys
import xmlrpc.client

URL = os.environ.get("ODOO_URL", "http://localhost:8069")
DB = os.environ.get("ODOO_DB", "shop")
ADMIN_PW = os.environ["ODOO_ADMIN_PASSWORD"]
GROUP_NAME = "Almi-Chain / Management"
MANAGEMENT_USERS = ["admin", "manager"]
# Root menus a cashier does not need (Odoo external identifier)
MENUS = {
    "contacts.menu_contacts": "Contacts",
    "hr.menu_hr_root": "Employees",
    "mail.menu_root_discuss": "Discuss",
    "calendar.mail_menu_calendar": "Calendar",
    "spreadsheet_dashboard.spreadsheet_dashboard_menu_root": "Dashboards",
    "base.menu_management": "Apps",
}
PARAMETER = "almi_chain.original_menus"

uid = xmlrpc.client.ServerProxy(f"{URL}/xmlrpc/2/common").authenticate(DB, "admin", ADMIN_PW, {})
if not uid:
    sys.exit("Could not log in as admin: check ODOO_ADMIN_PASSWORD")
obj = xmlrpc.client.ServerProxy(f"{URL}/xmlrpc/2/object", allow_none=True)


def x(model, method, *a, **kw):
    return obj.execute_kw(DB, uid, ADMIN_PW, model, method, list(a), kw)


def ref(xmlid):
    module, name = xmlid.split(".")
    r = x("ir.model.data", "search_read", [["module", "=", module], ["name", "=", name]], fields=["res_id"])
    return r[0]["res_id"] if r else None


def groups_field(model, *candidates):
    """Name of the groups field (Odoo 19 uses group_ids; older versions, groups_id)."""
    fields = x(model, "fields_get", attributes=["type"])
    for c in candidates:
        if c in fields:
            return c
    sys.exit(f"{model} has none of the fields {candidates}")


menu_field = groups_field("ir.ui.menu", "group_ids", "groups_id")
user_field = groups_field("res.users", "group_ids", "groups_id")
undo = "--undo" in sys.argv

group = x("res.groups", "search", [["name", "=", GROUP_NAME]], limit=1)
group = group[0] if group else x("res.groups", "create", {"name": GROUP_NAME})
print(f"==> Group '{GROUP_NAME}' (id {group})")

for login in MANAGEMENT_USERS:
    u = x("res.users", "search", [["login", "=", login]], limit=1)
    if u:
        x("res.users", "write", u, {user_field: [(4, group)]})
        print(f"    {login}: in the group")
    else:
        print(f"    WARNING: user {login} does not exist")

originals = json.loads(x("ir.config_parameter", "get_param", PARAMETER) or "{}")

print(f"==> Menus {'(undoing)' if undo else ''}")
for xmlid, name in MENUS.items():
    menu = ref(xmlid)
    if not menu:
        print(f"    {name}: not installed in this database ({xmlid}), skipped")
        continue
    if undo:
        if xmlid not in originals:
            print(f"    {name}: no saved original groups, left as it is")
            continue
        x("ir.ui.menu", "write", [menu], {menu_field: [(6, 0, originals[xmlid])]})
        print(f"    {name}: original groups {originals[xmlid]}")
        continue
    current = x("ir.ui.menu", "read", [menu], fields=[menu_field])[0][menu_field]
    if current != [group]:
        originals.setdefault(xmlid, [g for g in current if g != group])
    x("ir.ui.menu", "write", [menu], {menu_field: [(6, 0, [group])]})
    print(f"    {name}: management only (before: groups {originals.get(xmlid, [])})")

x("ir.config_parameter", "set_param", PARAMETER, "{}" if undo else json.dumps(originals))

print("\nDone. Check: log in as cashier1; only Point of Sale should be visible.")
