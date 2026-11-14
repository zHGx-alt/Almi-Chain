"""Tests for the fake Odoo XML-RPC server (standard library only).

Run from the repo root:  python -m unittest discover -s data-sync/fake_odoo -v
"""
import http.client
import socket
import threading
import unittest
import xmlrpc.client
from pathlib import Path

from fake_odoo import build_server

SEED = Path(__file__).with_name("seed.json")
PASSWORD = "test-password"


class TimeoutTransport(xmlrpc.client.Transport):
    """Gives up after 3 s instead of hanging forever when the server is blocked."""

    def make_connection(self, host):
        return http.client.HTTPConnection(host, timeout=3)


class FakeOdooTest(unittest.TestCase):
    def setUp(self):
        self.server = build_server("127.0.0.1", 0, PASSWORD, SEED)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        url = f"http://127.0.0.1:{self.server.server_address[1]}"
        self.common = xmlrpc.client.ServerProxy(f"{url}/xmlrpc/2/common")
        self.object = xmlrpc.client.ServerProxy(f"{url}/xmlrpc/2/object", allow_none=True)
        self.uid = self.common.authenticate("shop", "manager", PASSWORD, {})

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()

    def call(self, model, method, *args, **kwargs):
        return self.object.execute_kw("shop", self.uid, PASSWORD, model, method, list(args), kwargs)

    def test_authenticate_ok_and_wrong_password(self):
        self.assertEqual(self.uid, 2)
        self.assertIs(self.common.authenticate("shop", "manager", "wrong", {}), False)
        self.assertIs(self.common.authenticate("other_db", "manager", PASSWORD, {}), False)

    def test_wrong_password_on_object_faults(self):
        with self.assertRaises(xmlrpc.client.Fault):
            self.object.execute_kw("shop", self.uid, "wrong", "product.template", "search", [[]], {})

    def test_search_by_default_code_false(self):
        ids = self.call("product.template", "search", [["name", "=", "Gilda"], ["default_code", "=", False]], limit=1)
        self.assertEqual(len(ids), 1)

    def test_create_then_search_by_ref(self):
        new_id = self.call("product.template", "create", {"name": "New dish", "default_code": "ALMI-99"})
        self.assertEqual(self.call("product.template", "search", [["default_code", "=", "ALMI-99"]], limit=1), [new_id])

    def test_write_changes_list_price(self):
        ids = self.call("product.template", "search", [["name", "=", "Gilda"]], limit=1)
        self.assertTrue(self.call("product.template", "write", ids, {"list_price": 2.2}))
        self.assertEqual(self.call("product.template", "read", ids, ["list_price"])[0]["list_price"], 2.2)

    def test_read_missing_field_is_false(self):
        ids = self.call("product.template", "search", [["name", "=", "Gilda"]], limit=1)
        self.assertIs(self.call("product.template", "read", ids, ["default_code"])[0]["default_code"], False)

    def test_tax_copy_returns_new_id(self):
        base = self.call("account.tax", "search", [["type_tax_use", "=", "sale"], ["amount", "=", 10],
                                                   ["amount_type", "=", "percent"]], limit=1)
        new_id = self.call("account.tax", "copy", base[0], {"name": "10% VAT incl."})
        self.assertNotEqual(new_id, base[0])
        self.assertEqual(self.call("account.tax", "search", [["name", "=", "10% VAT incl."]], limit=1), [new_id])

    def test_many2many_command_is_stored(self):
        cat = self.call("pos.category", "create", {"name": "Specials"})
        new_id = self.call("product.template", "create", {"name": "X", "pos_categ_ids": [(6, 0, [cat])]})
        self.assertEqual(self.call("product.template", "read", [new_id], ["pos_categ_ids"])[0]["pos_categ_ids"], [cat])

    def test_idle_connection_does_not_block_other_clients(self):
        idle = socket.create_connection(self.server.server_address)  # connected, never sends a request
        try:
            url = f"http://127.0.0.1:{self.server.server_address[1]}/xmlrpc/2/common"
            transport = TimeoutTransport()
            proxy = xmlrpc.client.ServerProxy(url, transport=transport)
            self.assertEqual(proxy.authenticate("shop", "manager", PASSWORD, {}), 2)
        finally:
            idle.close()

    def test_unknown_method_faults(self):
        with self.assertRaises(xmlrpc.client.Fault) as ctx:
            self.call("product.template", "unlink", [1])
        self.assertIn("not implemented", ctx.exception.faultString)

    def test_unknown_domain_operator_faults(self):
        with self.assertRaises(xmlrpc.client.Fault) as ctx:
            self.call("product.template", "search", [["name", "ilike", "gil"]])
        self.assertIn("not implemented", ctx.exception.faultString)


if __name__ == "__main__":
    unittest.main()
