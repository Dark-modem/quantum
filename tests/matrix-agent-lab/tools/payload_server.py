#!/usr/bin/env python3
"""payload_server.py — lab payload endpoint (GET + PUT) with byte accounting.

Runs inside the kharej lab namespace, bound to the Matrix interface
address, so the ONLY way to reach it is through the tunnel.
stdlib only. Never used against production.
"""
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CHUNK = b"\xa5" * (256 * 1024)  # deterministic 256 KiB pattern


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # keep stdout clean for reports
        sys.stderr.write("[payload-server] %s\n" % (fmt % args))

    def do_GET(self):
        # GET /<mib>mib  -> exactly mib MiB of deterministic bytes
        try:
            mib = int(self.path.strip("/").replace("mib", ""))
        except ValueError:
            self.send_error(400, "path must be /<mib>mib")
            return
        total = mib * 1024 * 1024
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(total))
        self.end_headers()
        sent = 0
        try:
            while sent < total:
                n = min(len(CHUNK), total - sent)
                self.wfile.write(CHUNK[:n])
                sent += n
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_PUT(self):
        # PUT /upload — consume Content-Length bytes, report exact count.
        length = int(self.headers.get("Content-Length", "0"))
        received = 0
        try:
            while received < length:
                block = self.rfile.read(min(256 * 1024, length - received))
                if not block:
                    break
                received += len(block)
        except (ConnectionResetError, BrokenPipeError):
            pass
        body = ('{"received": %d, "expected": %d}' % (received, length)).encode()
        self.send_response(200 if received == length else 299)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def main():
    bind = sys.argv[1] if len(sys.argv) > 1 else "0.0.0.0"
    port = int(sys.argv[2] if len(sys.argv) > 2 else 8080)
    srv = ThreadingHTTPServer((bind, port), Handler)
    sys.stderr.write("[payload-server] listening on %s:%d\n" % (bind, port))
    srv.serve_forever()


if __name__ == "__main__":
    main()
