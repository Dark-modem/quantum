#!/usr/bin/env python3
"""dpi_prober.py — active probing of the lab tunnel port.

Usage: dpi_prober.py <target_ip> <port> <outfile.json>
Runs a fixed set of harmless probes (like a DPI box would) and records
F ACTUAL observed behavior: response bytes, RST vs timeout, timing.
No assumptions, no verdicts beyond what was observed. stdlib only.
"""
import json
import socket
import ssl
import struct
import sys
import time

TIMEOUT = 5.0


def tcp_probe(name, target, port, payload=b"", read=True, half_close=False):
    rec = {"probe": name, "transport": "tcp"}
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(TIMEOUT)
    t0 = time.monotonic()
    try:
        s.connect((target, port))
        rec["connect"] = "accepted"
        if payload:
            s.sendall(payload)
        if half_close:
            try:
                s.shutdown(socket.SHUT_WR)
            except OSError:
                pass
        if read:
            try:
                data = s.recv(4096)
                rec["response_bytes"] = len(data)
                rec["response_hex_head"] = data[:64].hex()
                rec["response_ascii"] = "".join(chr(c) if 32 <= c < 127 else "." for c in data[:64])
            except socket.timeout:
                rec["response_bytes"] = 0
                rec["behavior"] = "no response (timeout)"
    except ConnectionRefusedError:
        rec["connect"] = "refused"
    except ConnectionResetError:
        rec["connect"] = rec.get("connect", "connected")
        rec["behavior"] = "connection reset (RST)"
    except socket.timeout:
        rec["connect"] = rec.get("connect", "attempted")
        rec["behavior"] = "connect timeout (silent drop)"
    except OSError as e:
        rec["error"] = str(e)
    rec["elapsed_s"] = round(time.monotonic() - t0, 3)
    try:
        s.close()
    except OSError:
        pass
    return rec


def udp_probe(name, target, port, payload):
    rec = {"probe": name, "transport": "udp"}
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(TIMEOUT)
    t0 = time.monotonic()
    try:
        s.sendto(payload, (target, port))
        data, _ = s.recvfrom(4096)
        rec["response_bytes"] = len(data)
        rec["response_hex_head"] = data[:64].hex()
        rec["response_ascii"] = "".join(chr(c) if 32 <= c < 127 else "." for c in data[:64])
    except socket.timeout:
        rec["response_bytes"] = 0
        rec["behavior"] = "no response (timeout)"
    except OSError as e:
        rec["error"] = str(e)
    rec["elapsed_s"] = round(time.monotonic() - t0, 3)
    s.close()
    return rec


# A minimal TLS 1.2 ClientHello (SNI: probe.example.com) — if the service
# were TLS, this elicits a ServerHello; tinc is not, and we MEASURE that.
def tls_client_hello():
    sni = b"probe.example.com"
    ext_sni = b"\x00\x00" + struct.pack(">H", len(sni) + 5) + struct.pack(">H", len(sni) + 3) + b"\x00" + struct.pack(">H", len(sni)) + sni
    exts = ext_sni
    body = (b"\x03\x03" + b"\x00" * 32 +
            b"\x00" +
            struct.pack(">H", 2) + b"\x13\x01" +
            b"\x01\x00" +
            struct.pack(">H", len(exts)) + exts)
    hs = b"\x01" + struct.pack(">I", len(body))[1:] + body
    return b"\x16\x03\x01" + struct.pack(">H", len(hs)) + hs


def main():
    target, port, outfile = sys.argv[1], int(sys.argv[2]), sys.argv[3]
    probes = [
        tcp_probe("tcp_connect_close", target, port, read=False, half_close=True),
        tcp_probe("tcp_garbage_bytes", target, port, payload=b"\xde\xad\xbe\xef" * 8),
        tcp_probe("http_get", target, port, payload=b"GET / HTTP/1.0\r\nHost: probe\r\n\r\n"),
        tcp_probe("tls_client_hello", target, port, payload=tls_client_hello()),
        tcp_probe("tinc_style_id_line", target, port, payload=b"probe 1.1pre18 matrix\x00"),
        udp_probe("udp_single_packet", target, port, b"\x00probe-udp"),
    ]
    json.dump({"target": target, "port": port, "probes": probes},
              open(outfile, "w"), indent=2)
    slim = json.dumps([{k: v for k, v in p.items() if k != "response_hex_head"} for p in probes])
    print(slim)


if __name__ == "__main__":
    main()
