"""Tests for import_export.py against the fake Odoo (standard library only).

Run from the repo root:  python -m unittest discover -s data-sync/csv -v
"""
import os
import subprocess
import sys
import tempfile
import threading
import unittest
import xmlrpc.client
from pathlib import Path

HERE = Path(__file__).parent
sys.path.insert(0, str(HERE.parent / "fake_odoo"))
from fake_odoo import build_server  # noqa: E402

PASSWORD = "test-password"


class ImportTest(unittest.TestCase):
    def setUp(self):
        self.server = build_server("127.0.0.1", 0, PASSWORD, HERE.parent / "fake_odoo" / "seed.json")
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}"
        self.object = xmlrpc.client.ServerProxy(f"{self.url}/xmlrpc/2/object", allow_none=True)
        self.tmp = tempfile.TemporaryDirectory()

    def tearDown(self):
        self.tmp.cleanup()
        self.server.shutdown()
        self.server.server_close()

    def products(self):
        return self.object.execute_kw("shop", 2, PASSWORD, "product.template", "search_read", [[]],
                                      {"fields": ["name", "list_price"]})

    def run_import(self, csv_name):
        env = {**os.environ, "ODOO_URL": self.url, "ODOO_PASSWORD": PASSWORD, "PYTHONIOENCODING": "utf-8"}
        return subprocess.run([sys.executable, str(HERE / "import_export.py"), "import", str(HERE / csv_name)],
                              env=env, capture_output=True, text=True, encoding="utf-8")

    def test_good_menu_imports_every_row(self):
        result = self.run_import("menu.csv")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Import: 2 new, 12 updated, 0 with errors (14 rows", result.stdout)
        names = {p["name"]: p["list_price"] for p in self.products()}
        self.assertEqual(names["Café con leche"], 1.80)
        self.assertEqual(len(names), 14)

    def test_menu_with_errors_imports_nothing(self):
        before = self.products()
        result = self.run_import("menu-with-errors.csv")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("line 2: invalid price 'abc'", result.stdout)
        self.assertIn("line 7: invalid price '-15'", result.stdout)
        self.assertIn("Nothing imported", result.stdout)
        self.assertEqual(self.products(), before)


    def test_short_row_and_nan_are_listed_and_nothing_imported(self):
        bad = Path(self.tmp.name) / "bad.csv"
        bad.write_text("category;product;price_incl_vat;description\n"
                       "Starters;Gilda\n"
                       "Mains;Marmitako;nan;Tuna stew\n"
                       "Drinks;Caña;2.50;Draught beer\n", encoding="utf-8")
        before = self.products()
        result = self.run_import(str(bad))
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("Traceback", result.stderr)
        self.assertIn("line 2: wrong number of columns", result.stdout)
        self.assertIn("line 3: invalid price 'nan'", result.stdout)
        self.assertEqual(self.products(), before)


if __name__ == "__main__":
    unittest.main()
