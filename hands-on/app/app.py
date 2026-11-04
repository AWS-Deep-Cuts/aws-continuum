"""Record shop search API.

Usage:
    python3 app.py

Environment variables:
    HOST  address to listen on (default: 127.0.0.1)
    PORT  port to listen on (default: 8080)
"""

import csv
import json
import os
import sqlite3
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
DATA_DIR = os.path.join(BASE_DIR, "data")

TOP_COLUMNS = {"price": "price", "year": "year", "title": "title"}
TOP_LIMIT = 3


def load_db():
    conn = sqlite3.connect(":memory:", check_same_thread=False)
    conn.execute(
        "CREATE TABLE records (id INTEGER PRIMARY KEY, title TEXT, artist TEXT, year INTEGER, price INTEGER)"
    )
    conn.execute("CREATE TABLE customers (id INTEGER PRIMARY KEY, name TEXT, email TEXT)")
    with open(os.path.join(DATA_DIR, "records.csv"), newline="", encoding="utf-8") as f:
        rows = [(int(r["id"]), r["title"], r["artist"], int(r["year"]), int(r["price"])) for r in csv.DictReader(f)]
    conn.executemany("INSERT INTO records VALUES (?, ?, ?, ?, ?)", rows)
    with open(os.path.join(DATA_DIR, "customers.csv"), newline="", encoding="utf-8") as f:
        rows = [(int(r["id"]), r["name"], r["email"]) for r in csv.DictReader(f)]
    conn.executemany("INSERT INTO customers VALUES (?, ?, ?)", rows)
    conn.commit()
    return conn


DB = load_db()
DB_LOCK = threading.Lock()


def to_items(rows):
    return [{"title": r[0], "artist": r[1], "year": r[2], "price": r[3]} for r in rows]


def search_records(q):
    sql = "SELECT title, artist, year, price FROM records WHERE title LIKE '%" + q + "%' ORDER BY id"
    with DB_LOCK:
        return to_items(DB.execute(sql).fetchall())


def top_records(by):
    column = TOP_COLUMNS.get(by, "title")
    direction = "ASC" if column == "title" else "DESC"
    sql = f"SELECT title, artist, year, price FROM records ORDER BY {column} {direction} LIMIT ?"
    with DB_LOCK:
        return to_items(DB.execute(sql, (TOP_LIMIT,)).fetchall())


class Handler(BaseHTTPRequestHandler):
    def send_json(self, status, body):
        data = json.dumps(body, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        url = urlparse(self.path)
        params = parse_qs(url.query)
        try:
            if url.path == "/health":
                self.send_json(200, {"status": "ok"})
            elif url.path == "/records":
                q = params.get("q", [""])[0]
                self.send_json(200, {"items": search_records(q)})
            elif url.path == "/records/top":
                by = params.get("by", ["title"])[0]
                self.send_json(200, {"by": TOP_COLUMNS.get(by, "title"), "items": top_records(by)})
            else:
                self.send_json(404, {"error": "not found"})
        except sqlite3.Error:
            self.send_json(500, {"error": "database error"})

    def log_message(self, fmt, *args):
        print("%s %s" % (self.address_string(), fmt % args), flush=True)


def make_server(host, port):
    return ThreadingHTTPServer((host, port), Handler)


def main():
    host = os.environ.get("HOST", "127.0.0.1")
    port = int(os.environ.get("PORT", "8080"))
    server = make_server(host, port)
    print(f"listening on http://{host}:{port}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
