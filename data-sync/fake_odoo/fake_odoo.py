#!/usr/bin/env python3
"""In-memory stand-in for Odoo's XML-RPC API, for the one-command demo. NOT a real Odoo.

It implements only what the sync and the CSV import use:
  /xmlrpc/2/common  authenticate(db, login, password, {})
  /xmlrpc/2/object  execute_kw(db, uid, password, model, method, args, kwargs)
    product.template  search, read, search_read, write, create
    pos.category      search, create
    account.tax       search, copy
Domains support "=", "!=" and "in", combined with AND. Anything else raises an
XML-RPC Fault saying it is not implemented, so a script never gets a silent wrong answer.

State lives in memory and starts from seed.json; restarting the server resets it.

Environment: FAKE_ODOO_PASSWORD (required), FAKE_ODOO_PORT (default 8069).
Login: database "shop", user "manager".
"""
import copy
import json
import os
import sys
import threading
from pathlib import Path
from socketserver import ThreadingMixIn
from xmlrpc.client import Fault
from xmlrpc.server import SimpleXMLRPCRequestHandler, SimpleXMLRPCServer

DB = "shop"
LOGIN = "manager"
UID = 2
METHODS = {
    "product.template": {"search", "read", "search_read", "write", "create"},
    "pos.category": {"search", "create"},
    "account.tax": {"search", "copy"},
}
OPERATORS = {"=", "!=", "in"}


class Store:
    def __init__(self, seed):
        self.records = {model: {r["id"]: dict(r) for r in rows} for model, rows in seed.items()}
        for model in METHODS:
            self.records.setdefault(model, {})

    @staticmethod
    def _value(value):
        """Many2many commands [(6, 0, ids)] are stored as the plain id list."""
        if isinstance(value, list) and value and isinstance(value[0], (list, tuple)) and value[0][0] == 6:
            return list(value[0][2])
        return value

    def _matches(self, record, domain):
        for term in domain:
            field, op, expected = term
            if op not in OPERATORS:
                raise Fault(1, f"fake_odoo: domain operator {op!r} not implemented")
            actual = record.get(field, False)
            if op == "=" and actual != expected:
                return False
            if op == "!=" and actual == expected:
                return False
            if op == "in" and actual not in expected:
                return False
        return True

    def search(self, model, domain, limit=None, order=None):
        ids = [i for i, r in sorted(self.records[model].items()) if self._matches(r, domain)]
        return ids[:limit] if limit else ids

    def read(self, model, ids, fields=None):
        rows = []
        for i in ids:
            record = self.records[model][i]
            names = fields or list(record)
            rows.append({"id": i, **{f: record.get(f, False) for f in names if f != "id"}})
        return rows

    def search_read(self, model, domain, fields=None, limit=None, order=None):
        return self.read(model, self.search(model, domain, limit=limit), fields)

    def create(self, model, values):
        new_id = max(self.records[model], default=0) + 1
        self.records[model][new_id] = {"id": new_id, **{k: self._value(v) for k, v in values.items()}}
        return new_id

    def write(self, model, ids, values):
        for i in ids:
            self.records[model][i].update({k: self._value(v) for k, v in values.items()})
        return True

    def copy(self, model, record_id, default=None):
        values = copy.deepcopy(self.records[model][record_id])
        values.pop("id")
        values.update(default or {})
        return self.create(model, values)


class FakeOdoo:
    def __init__(self, password, seed):
        self.password = password
        self.store = Store(seed)
        self.lock = threading.Lock()  # one call at a time touches the data

    def authenticate(self, db, login, password, _context):
        return UID if (db, login, password) == (DB, LOGIN, self.password) else False

    def execute_kw(self, db, uid, password, model, method, args, kwargs=None):
        if (db, uid, password) != (DB, UID, self.password):
            raise Fault(3, "fake_odoo: access denied")
        if method not in METHODS.get(model, set()):
            raise Fault(1, f"fake_odoo: {model}.{method} not implemented")
        with self.lock:
            return getattr(self.store, method)(model, *args, **(kwargs or {}))


class ThreadedServer(ThreadingMixIn, SimpleXMLRPCServer):
    """One thread per connection: a client holding a keep-alive connection open
    must not block the others (real Odoo serves clients concurrently too)."""
    daemon_threads = True


class Handler(SimpleXMLRPCRequestHandler):
    rpc_paths = ("/xmlrpc/2/common", "/xmlrpc/2/object")

    def log_message(self, *args):  # keep the demo output readable
        pass


def build_server(host, port, password, seed_path):
    """Returns a ready-to-serve XML-RPC server for both Odoo endpoints."""
    api = FakeOdoo(password, json.loads(Path(seed_path).read_text(encoding="utf-8")))
    server = ThreadedServer((host, port), requestHandler=Handler, allow_none=True, logRequests=False)
    server.register_function(api.authenticate, "authenticate")
    server.register_function(api.execute_kw, "execute_kw")
    return server


def main():
    password = os.environ.get("FAKE_ODOO_PASSWORD") or sys.exit("FAKE_ODOO_PASSWORD is not set")
    port = int(os.environ.get("FAKE_ODOO_PORT", "8069"))
    server = build_server("0.0.0.0", port, password, Path(__file__).with_name("seed.json"))
    print(f"fake_odoo: in-memory stand-in for Odoo's XML-RPC API, not a real Odoo (port {port})", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
