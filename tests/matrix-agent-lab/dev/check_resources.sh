#!/usr/bin/env bash
# dev/check_resources.sh — verify the CPU sampler data of the latest run (debug aid)
R=$(ls -td /opt/qmx-lab/results/run-* | head -1)
echo "run: $R"
head -3 "$R/samples/resources.csv"
echo "..."
awk -F, 'NR>1 && $3!="NA" {
    if (first[$2]=="") first[$2]=$3; last[$2]=$3; n++
}
END {
    for (k in first) printf "pid %s ticks %s -> %s (delta %d)\n", k, first[k], last[k], last[k]-first[k]
    print "sample rows:", n
}' "$R/samples/resources.csv"
# recompute jitter from raw latency samples in arrival order vs sorted
python3 - "$R" <<'PYEOF'
import json, sys, os, re
r = sys.argv[1]
p = os.path.join(r, "samples", "latency.txt")
if not os.path.exists(p):
    print("no latency.txt")
    raise SystemExit
vals = []
for line in open(p, errors="replace"):
    if "time=" in line:
        vals.append(float(re.search(r"time=([0-9.]+)", line).group(1)))
diffs_arrival = [abs(vals[i]-vals[i-1]) for i in range(1, len(vals))]
diffs_sorted = [abs(sorted(vals)[i]-sorted(vals)[i-1]) for i in range(1, len(vals))]
print(f"jitter arrival-order: {sum(diffs_arrival)/len(diffs_arrival):.3f} ms")
print(f"jitter sorted-order : {sum(diffs_sorted)/len(diffs_sorted):.3f} ms  (wrong definition)")
PYEOF
