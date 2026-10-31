#!/usr/bin/env python3
"""udp_probe.py — UDP loss/jitter probe (RFC 3550-style mean deviation).

Usage:
  udp_probe.py server <bind_ip> <port>
  udp_probe.py client <target_ip> <port> <count> <rate_hz> <outfile.json>

Server echoes datagrams back prefixed with 'E'. Client measures RTT per
packet, computes loss %, RTT min/mean/p95/max and jitter (mean absolute
deviation of consecutive RTT differences). stdlib only.
"""
import json
import socket
import sys
import time


def server(bind_ip, port):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind((bind_ip, port))
    while True:
        data, addr = s.recvfrom(65535)
        if data.startswith(b"E"):
            s.sendto(data, addr)


def client(target, port, count, rate, outfile):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(2.0)
    rtts = []
    sent = 0
    got = 0
    interval = 1.0 / rate
    t0 = time.monotonic()
    for seq in range(count):
        send_at = t0 + seq * interval
        delay = send_at - time.monotonic()
        if delay > 0:
            time.sleep(delay)
        msg = b"E%06d %.6f" % (seq, time.monotonic())
        try:
            s.sendto(msg, (target, port))
            sent += 1
        except OSError:
            break
        deadline = time.monotonic() + 2.0
        s.settimeout(max(0.01, deadline - time.monotonic()))
        try:
            data, _ = s.recvfrom(65535)
            if data.startswith(b"E"):
                parts = data.decode().split()
                if parts[1:] :
                    rtt = time.monotonic() - float(parts[1])
                    rtts.append((seq, rtt * 1000.0))
                    got += 1
        except socket.timeout:
            pass

    rtts_ms = [r for _, r in rtts]
    rtts_ms.sort()
    loss_pct = 100.0 * (sent - got) / sent if sent else 100.0
    # RFC 3550 jitter: mean absolute consecutive difference
    jitter = None
    if len(rtts_ms) >= 2:
        diffs = [abs(rtts_ms[i] - rtts_ms[i - 1]) for i in range(1, len(rtts_ms))]
        jitter = round(sum(diffs) / len(diffs), 3)

    def pct(p):
        if not rtts_ms:
            return None
        k = max(0, min(len(rtts_ms) - 1, int(round(p / 100.0 * (len(rtts_ms) - 1)))))
        return round(rtts_ms[k], 3)

    result = {
        "sent": sent, "received": got, "loss_pct": round(loss_pct, 3),
        "rtt_ms": {"min": pct(0), "mean": pct(50), "p95": pct(95), "max": pct(100)},
        "jitter_ms": jitter,
        "samples_ms": [round(r, 3) for r in rtts_ms],
        "status": "ok" if sent else "error",
    }
    with open(outfile, "w") as f:
        json.dump(result, f, indent=2)
    print(json.dumps({k: v for k, v in result.items() if k != "samples_ms"}))


if __name__ == "__main__":
    if sys.argv[1] == "server":
        server(sys.argv[2], int(sys.argv[3]))
    else:
        client(sys.argv[2], int(sys.argv[3]), int(sys.argv[4]),
               float(sys.argv[5]), sys.argv[6])
