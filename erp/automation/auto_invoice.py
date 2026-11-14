#!/usr/bin/env python3
"""
End-to-end automated use case: issue an invoice in Odoo.

Does through the XML-RPC API, with no clicks, the same steps the manager would do by hand:
  1. Find or create the customer
  2. Find or create the product
  3. Create the sales order and confirm it
  4. Create the invoice and post it (journal entry with its VAT)
  5. Register the payment
  6. Download the invoice PDF

Usage:
  read -rs ODOO_PASSWORD && export ODOO_PASSWORD
  ODOO_URL=http://localhost:8069 ODOO_DB=shop ODOO_USER=manager \
  python3 auto_invoice.py --customer "Example Events Ltd" --product "Group menu (event)" --price 30 --quantity 20

The restaurant's real use case: a company books a group lunch and asks for a full invoice
(with its tax ID), not the POS's simplified receipt. Restaurant VAT is 10 % (--vat 10, the default).

Runs as the "manager" user, not admin (least privilege).
"""
import argparse
import http.cookiejar
import json
import os
import sys
import urllib.request
import xmlrpc.client

URL = os.environ.get("ODOO_URL", "http://localhost:8069")
DB = os.environ.get("ODOO_DB", "shop")
USER = os.environ.get("ODOO_USER", "manager")
PASSWORD = os.environ["ODOO_PASSWORD"]

p = argparse.ArgumentParser(description="Issues an invoice end to end in Odoo")
p.add_argument("--customer", default="Example Events Ltd")
p.add_argument("--email", default="bookings@events.example.test")
p.add_argument("--product", default="Group menu (event)")
p.add_argument("--price", type=float, default=30.00, help="price per guest before VAT")
p.add_argument("--quantity", type=float, default=20, help="guests")
p.add_argument("--vat", type=float, default=10, choices=[10, 21], help="10 = restaurant; 21 = other services")
p.add_argument("--pdf-dir", default=".")
args = p.parse_args()

uid = xmlrpc.client.ServerProxy(f"{URL}/xmlrpc/2/common").authenticate(DB, USER, PASSWORD, {})
if not uid:
    sys.exit(f"Could not log in as {USER}")
obj = xmlrpc.client.ServerProxy(f"{URL}/xmlrpc/2/object", allow_none=True)


def x(model, method, *a, **kw):
    return obj.execute_kw(DB, uid, PASSWORD, model, method, list(a), kw)


def button(model, method, *a, **kw):
    """Presses an Odoo button. Some return a screen action with None values that XML-RPC cannot
    send back: the button has already run, so that error is ignored and the result checked later."""
    try:
        return x(model, method, *a, **kw)
    except xmlrpc.client.Fault as e:
        if "cannot marshal None" not in e.faultString:
            raise


def step(n, text):
    print(f"[{n}/6] {text}", flush=True)


# 1. Customer
customer = x("res.partner", "search", [["name", "=", args.customer]], limit=1)
customer = customer[0] if customer else x("res.partner", "create", {
    "name": args.customer, "email": args.email,
    "country_id": x("res.country", "search", [["code", "=", "ES"]])[0]})
step(1, f"Customer: {args.customer} (id {customer})")

# 2. Product: a service (the meal served on the premises), so it takes the SERVICES VAT, not the
#    goods VAT. In the Spanish localisation the difference matters for the VAT return (form 303).
vat_domain = [["type_tax_use", "=", "sale"], ["amount", "=", args.vat], ["amount_type", "=", "percent"]]
vat = (x("account.tax", "search", vat_domain + [["tax_scope", "=", "service"]], limit=1)
       or x("account.tax", "search", vat_domain, limit=1))
if not vat:
    sys.exit(f"Odoo has no {args.vat:g} % sales tax")
product = x("product.product", "search", [["name", "=", args.product]], limit=1)
if product:
    product = product[0]
    x("product.product", "write", [product], {"taxes_id": [(6, 0, vat)]})
else:
    template = x("product.template", "create", {
        "name": args.product, "type": "service", "list_price": args.price,
        "invoice_policy": "order", "taxes_id": [(6, 0, vat)], "available_in_pos": True})
    product = x("product.product", "search", [["product_tmpl_id", "=", template]])[0]
vat_name = x("account.tax", "read", vat, fields=["name"])[0]["name"]
step(2, f"Product: {args.product} at {args.price:.2f} EUR + VAT {vat_name} (id {product})")

# 3. Sales order
order = x("sale.order", "create", {
    "partner_id": customer,
    # The VAT is also set on the line: otherwise a product that already existed with another tax (or a
    # customer fiscal position) can add a second VAT. It happened once: 654.55 EUR instead of 660.00 EUR.
    "order_line": [(0, 0, {"product_id": product, "product_uom_qty": args.quantity, "price_unit": args.price,
                           "tax_ids": [(6, 0, vat)]})]})
button("sale.order", "action_confirm", [order])
o_info = x("sale.order", "read", [order], fields=["name", "state", "amount_total"])[0]
step(3, f"Order {o_info['name']} confirmed ({o_info['state']}), total {o_info['amount_total']:.2f} EUR")

# 4. Invoice: the order's "Create invoice" wizard, then post it
wizard = x("sale.advance.payment.inv", "create", {"advance_payment_method": "delivered",
                                                  "sale_order_ids": [(6, 0, [order])]})
button("sale.advance.payment.inv", "create_invoices", [wizard])
invoice = x("sale.order", "read", [order], fields=["invoice_ids"])[0]["invoice_ids"][-1]
button("account.move", "action_post", [invoice])
i_info = x("account.move", "read", [invoice],
           fields=["name", "state", "amount_untaxed", "amount_tax", "amount_total", "invoice_date"])[0]
step(4, f"Invoice {i_info['name']} posted on {i_info['invoice_date']}: "
        f"base {i_info['amount_untaxed']:.2f} EUR + VAT {i_info['amount_tax']:.2f} EUR = {i_info['amount_total']:.2f} EUR")
expected = round(args.price * args.quantity * (1 + args.vat / 100), 2)
if abs(i_info["amount_total"] - expected) > 0.01:
    sys.exit(f"ERROR: the invoice totals {i_info['amount_total']:.2f} EUR and should be {expected:.2f} EUR "
             f"({args.quantity:g} x {args.price:.2f} EUR + {args.vat:g} % VAT). Check the taxes on product "
             f"'{args.product}' and that the sales VAT is not 'included in price'. The invoice is posted "
             f"but unpaid: cancel it with a credit note.")

# 5. Payment: the "Register payment" wizard
ctx = {"active_model": "account.move", "active_ids": [invoice]}
payment = x("account.payment.register", "create", {}, context=ctx)
button("account.payment.register", "action_create_payments", [payment], context=ctx)
payment_state = x("account.move", "read", [invoice], fields=["payment_state"])[0]["payment_state"]
step(5, f"Payment registered: payment state '{payment_state}'")

# 6. PDF (the report is downloaded over HTTP with a web session)
session = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
body = json.dumps({"jsonrpc": "2.0", "params": {"db": DB, "login": USER, "password": PASSWORD}}).encode()
session.open(urllib.request.Request(f"{URL}/web/session/authenticate", body, {"Content-Type": "application/json"}))
pdf = session.open(f"{URL}/report/pdf/account.report_invoice/{invoice}").read()
if not pdf.startswith(b"%PDF"):
    sys.exit("The server did not return a PDF")
path = os.path.join(args.pdf_dir, f"{i_info['name'].replace('/', '_')}.pdf")
with open(path, "wb") as f:
    f.write(pdf)
step(6, f"PDF saved to {path} ({len(pdf) // 1024} KB)")
print(f"\nOK · {o_info['name']} -> {i_info['name']} · {i_info['amount_total']:.2f} EUR · {payment_state}")
