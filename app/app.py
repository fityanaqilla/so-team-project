#!/usr/bin/env python3
"""Backend sederhana (tier 2): stdlib http.server + PyMySQL ke MariaDB (tier 3).

Endpoint:
  /         -> mencatat kunjungan ke DB, mengembalikan total kunjungan
  /health   -> 200 bila DB terjangkau, 503 bila tidak
  /whoami   -> header proxy yang diterima (bukti X-Real-IP diteruskan nginx)
Konfigurasi lewat environment (diisi systemd EnvironmentFile). Tidak ada secret di kode.
"""
import json
import logging
import os
import signal
import socketserver
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

try:
    import pymysql
except ImportError:  # app tetap hidup, /health akan melaporkan DB tidak tersedia
    pymysql = None

HOST = os.environ.get("APP_HOST", "127.0.0.1")
PORT = int(os.environ.get("APP_PORT", "8000"))
DATA_DIR = os.environ.get("APP_DATA_DIR", "/var/www/webapp/data")
LOG_DIR = os.environ.get("APP_LOG_DIR", "/var/log/webapp")
DB = {
    "host": os.environ.get("DB_HOST", "127.0.0.1"),
    "port": int(os.environ.get("DB_PORT", "3306")),
    "user": os.environ.get("DB_USER", ""),
    "password": os.environ.get("DB_PASS", ""),
    "database": os.environ.get("DB_NAME", ""),
}

log = logging.getLogger("webapp")
_schema_ready = False
_schema_lock = threading.Lock()


def setup_logging():
    handlers = [logging.StreamHandler(sys.stdout)]  # -> journald
    try:
        handlers.append(logging.FileHandler(os.path.join(LOG_DIR, "app.log")))
    except OSError:
        pass
    logging.basicConfig(level=logging.INFO, handlers=handlers,
                        format="%(asctime)s %(levelname)s %(message)s")


def db_connect():
    if pymysql is None:
        raise RuntimeError("modul pymysql tidak terpasang")
    return pymysql.connect(connect_timeout=3, autocommit=True, **DB)


def ensure_schema():
    global _schema_ready
    if _schema_ready:
        return
    with _schema_lock:
        if _schema_ready:
            return
        conn = db_connect()
        try:
            with conn.cursor() as cur:
                cur.execute(
                    "CREATE TABLE IF NOT EXISTS visits ("
                    "id INT AUTO_INCREMENT PRIMARY KEY,"
                    "path VARCHAR(255) NOT NULL,"
                    "client_ip VARCHAR(64) NOT NULL,"
                    "created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP)")
            _schema_ready = True
        finally:
            conn.close()


class Handler(BaseHTTPRequestHandler):
    server_version = "webapp/1.0"

    def _send(self, code, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def client_ip(self):
        return self.headers.get("X-Real-IP") or self.client_address[0]

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        try:
            if path == "/health":
                ensure_schema()
                conn = db_connect()
                try:
                    with conn.cursor() as cur:
                        cur.execute("SELECT 1")
                finally:
                    conn.close()
                self._send(200, {"status": "ok", "db": "up"})
            elif path == "/whoami":
                self._send(200, {
                    "x_real_ip": self.headers.get("X-Real-IP"),
                    "x_forwarded_for": self.headers.get("X-Forwarded-For"),
                    "x_forwarded_proto": self.headers.get("X-Forwarded-Proto"),
                    "host": self.headers.get("Host"),
                })
            elif path == "/":
                ensure_schema()
                conn = db_connect()
                try:
                    with conn.cursor() as cur:
                        cur.execute("INSERT INTO visits (path, client_ip) VALUES (%s, %s)",
                                    (path, self.client_ip()[:64]))
                        cur.execute("SELECT COUNT(*) FROM visits")
                        total = cur.fetchone()[0]
                finally:
                    conn.close()
                self._send(200, {"app": "webapp", "message": "Multi-tier OK",
                                 "total_visits": total})
            else:
                self._send(404, {"error": "not found"})
        except Exception as exc:  # noqa: BLE001 — jangan bocorkan detail ke klien
            log.error("request %s gagal: %s", path, exc)
            self._send(503, {"status": "error", "db": "down"})

    def log_message(self, fmt, *args):
        log.info("%s %s", self.client_ip(), fmt % args)


class ThreadedServer(socketserver.ThreadingMixIn, HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def main():
    setup_logging()
    server = ThreadedServer((HOST, PORT), Handler)

    def stop(signum, _frame):
        log.info("Sinyal %s diterima, shutdown graceful...", signum)
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)

    try:  # bukti direktori data dapat ditulis di bawah ProtectSystem=strict
        with open(os.path.join(DATA_DIR, "last_start.json"), "w") as fh:
            json.dump({"started_at": time.strftime("%Y-%m-%dT%H:%M:%S"), "pid": os.getpid()}, fh)
    except OSError as exc:
        log.warning("tidak bisa menulis %s: %s", DATA_DIR, exc)

    log.info("Listening di http://%s:%d", HOST, PORT)
    server.serve_forever()
    server.server_close()
    log.info("Server berhenti.")


if __name__ == "__main__":
    main()
