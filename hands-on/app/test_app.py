import json
import os
import threading
import unittest
import urllib.request

import app
import partner_report

BASE_DIR = os.path.dirname(os.path.abspath(__file__))


class AppTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = app.make_server("127.0.0.1", 0)
        cls.port = cls.server.server_address[1]
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()

    def get(self, path):
        with urllib.request.urlopen(f"http://127.0.0.1:{self.port}{path}", timeout=5) as res:
            return res.status, json.loads(res.read().decode("utf-8"))

    def test_health(self):
        status, body = self.get("/health")
        self.assertEqual(status, 200)
        self.assertEqual(body["status"], "ok")

    def test_search_finds_one_record(self):
        status, body = self.get("/records?q=Blue")
        self.assertEqual(status, 200)
        self.assertEqual([i["title"] for i in body["items"]], ["Blue Harbor Lights"])

    def test_top_by_price_is_descending(self):
        _, body = self.get("/records/top?by=price")
        prices = [i["price"] for i in body["items"]]
        self.assertEqual(len(prices), 3)
        self.assertEqual(prices, sorted(prices, reverse=True))

    def test_top_with_unknown_key_uses_title(self):
        _, body = self.get("/records/top?by=unknown")
        titles = [i["title"] for i in body["items"]]
        self.assertEqual(body["by"], "title")
        self.assertEqual(titles, sorted(titles))

    def test_partner_report_includes_jacket_text(self):
        report = partner_report.build_report(os.path.join(BASE_DIR, "inbox", "sample-order.csv"))
        self.assertIn("Blue Harbor Lights", report)
        self.assertIn("青い線", report)


if __name__ == "__main__":
    unittest.main()
