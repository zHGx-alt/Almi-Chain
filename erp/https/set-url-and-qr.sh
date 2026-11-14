#!/usr/bin/env bash
# Pins Odoo's base URL (web.base.url + freeze) and removes the invoice QR code from the
# receipt: customers are on the guest Wi-Fi and cannot reach the server anyway.
#
# Usage (on the server):  sudo ./set-url-and-qr.sh [URL]     (default https://192.168.10.10)
# Idempotent. The POS picks it up when a new till session is opened.
set -euo pipefail
BASE_URL=${1:-https://192.168.10.10}
set -a; . /opt/odoo/.env; set +a
python3 - "$BASE_URL" <<'EOF'
import os, sys, xmlrpc.client
url, db, pw, base = "http://localhost:8069", os.environ["ODOO_DB"], os.environ["ODOO_ADMIN_PASSWORD"], sys.argv[1]
uid = xmlrpc.client.ServerProxy(f"{url}/xmlrpc/2/common").authenticate(db, "admin", pw, {})
m = xmlrpc.client.ServerProxy(f"{url}/xmlrpc/2/object")
x = lambda model, method, *args, **k: m.execute_kw(db, uid, pw, model, method, list(args), k)

print("### 1. Base URL")
print("before:", x("ir.config_parameter", "get_param", "web.base.url"), "· freeze:", x("ir.config_parameter", "get_param", "web.base.url.freeze"))
x("ir.config_parameter", "set_param", "web.base.url", base)
x("ir.config_parameter", "set_param", "web.base.url.freeze", "True")
print("now:   ", x("ir.config_parameter", "get_param", "web.base.url"), "· freeze:", x("ir.config_parameter", "get_param", "web.base.url.freeze"))

print("\n### 2. Invoice QR code on the receipt")
for model in ("res.company", "pos.config"):
    fields = {n: d for n, d in x(model, "fields_get", attributes=["type", "string", "store"]).items()
              if "qr" in n and d["type"] == "boolean" and d.get("store")}
    for name, d in fields.items():
        for r in x(model, "search_read", [], fields=[name, "name"]):
            print(f"{model}.{name} ({d['string']}) · {r['name']}: {r[name]}", end="")
            if "ticket" in name and r[name]:
                x(model, "write", [r["id"]], {name: False})
                print(" -> False", end="")
            print()
EOF
