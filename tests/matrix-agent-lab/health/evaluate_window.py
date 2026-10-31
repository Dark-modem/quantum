#!/usr/bin/env python3
"""evaluate_window.py — 60s rolling-window evaluation with hysteresis.

Usage: evaluate_window.py <latency.json> <thresholds.json>

Reads the lab latency samples ([[unix_ts, rtt_ms], ...] from
ping_stats.py) and simulates the future Quantum health monitor:
  * folds samples into 60-second rolling windows (non-overlapping)
  * computes mean / p95 / loss / jitter per window
  * applies thresholds.json with asymmetric hysteresis so temporary
    fluctuations do NOT flip the state (anti-flapping design)
Output: state timeline, per-window stats, and switch statistics that
quantify how often the design would have switched state.
stdlib only.
"""
import json
import math
import sys


def pct(xs, p):
    if not xs:
        return None
    xs = sorted(xs)
    k = max(0, min(len(xs) - 1, int(round(p / 100.0 * (len(xs) - 1)))))
    return xs[k]


def main():
    lat_path, thr_path = sys.argv[1], sys.argv[2]
    lat = json.load(open(lat_path))
    thr = json.load(open(thr_path))
    series = lat.get("series") or []
    if not series:
        print(json.dumps({"status": "no_series",
                          "note": "ping output lacked -D timestamps"}, indent=2))
        return

    win = int(thr.get("window_seconds", 60))
    fail_cfg = thr.get("window_fail_when", {})
    hyst = thr.get("hysteresis", {})
    n_degrade = int(hyst.get("consecutive_windows_to_degrade", 2))
    n_recover = int(hyst.get("consecutive_windows_to_recover", 3))

    # ---- fold into non-overlapping 60s windows
    t0 = math.floor(series[0][0])
    windows = {}
    for ts, ms in series:
        idx = int((ts - t0) // win)
        windows.setdefault(idx, []).append(ms)

    window_stats = []
    for idx in sorted(windows):
        xs = sorted(windows[idx])
        n = len(xs)
        diffs = [abs(xs[i] - xs[i - 1]) for i in range(1, n)]
        # transmitted count from the ping summary scaled per window
        tx = lat.get("transmitted") or n
        per_window_tx = max(n, round(tx * (n / max(1, len(series)))))
        loss = 100.0 * (per_window_tx - n) / per_window_tx if per_window_tx else 0.0
        fails = []
        if fail_cfg.get("loss_pct_gt") is not None and loss > fail_cfg["loss_pct_gt"]:
            fails.append("loss")
        if fail_cfg.get("p95_ms_gt") is not None and pct(xs, 95) > fail_cfg["p95_ms_gt"]:
            fails.append("p95")
        if fail_cfg.get("mean_ms_gt") is not None and (sum(xs) / n) > fail_cfg["mean_ms_gt"]:
            fails.append("mean")
        if fail_cfg.get("jitter_ms_gt") is not None and diffs and \
                (sum(diffs) / len(diffs)) > fail_cfg["jitter_ms_gt"]:
            fails.append("jitter")
        window_stats.append({
            "window_index": idx,
            "t_start": t0 + idx * win,
            "samples": n,
            "mean_ms": round(sum(xs) / n, 2),
            "p95_ms": pct(xs, 95),
            "jitter_ms": round(sum(diffs) / len(diffs), 2) if diffs else 0.0,
            "loss_pct": round(loss, 2),
            "window_failed": bool(fails),
            "failed_criteria": fails,
        })

    # ---- hysteresis state machine
    state = "healthy"
    fail_streak = good_streak = 0
    switches = []
    for w in window_stats:
        if w["window_failed"]:
            fail_streak += 1
            good_streak = 0
        else:
            good_streak += 1
            fail_streak = 0
        new = state
        if state == "healthy" and fail_streak >= n_degrade:
            new = "degraded"
        elif state == "degraded" and good_streak >= n_recover:
            new = "healthy"
        if new != state:
            switches.append({"at_window": w["window_index"], "from": state, "to": new})
            state = new
        w["state"] = state

    result = {
        "status": "evaluated",
        "window_seconds": win,
        "windows": window_stats,
        "hysteresis": {"degrade_after_n_fail_windows": n_degrade,
                        "recover_after_n_good_windows": n_recover},
        "state_switches": switches,
        "switch_rate_per_hour": round(3600 / win * len(switches) / max(1, len(window_stats)), 3),
        "final_state": state,
        "design_note": "asymmetric hysteresis suppresses flapping on temporary fluctuations",
    }
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
