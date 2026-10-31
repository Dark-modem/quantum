#!/usr/bin/env bash
# dev/check_summary.sh — run resource_summary from the real lib on the latest run
export LAB_ROOT=/opt/qmx-lab
cd /opt/qmx-lab
. lib/common.sh
. lib/netns.sh
. lib/engine.sh
. lib/traffic.sh
R=$(ls -td /opt/qmx-lab/results/run-* | head -1)
echo "run: $R"
echo "resource_summary output: [$(resource_summary "$R/samples/resources.csv")]"
clk=$(getconf CLK_TCK)
echo "CLK_TCK=$clk"
awk -F, -v clk="$clk" '
    $4 != "" && $4 != "NA" && $4+0 > peak { peak = $4+0 }
    { key=$2; if (first[key]=="") first[key]=$3; last[key]=$3;
      if (tsmin=="" || $1+0 < tsmin+0) tsmin=$1;
      if (tsmax=="" || $1+0 > tsmax+0) tsmax=$1 }
    END {
        dt=0
        for (k in first) dt += last[k]-first[k]
        wall = tsmax-tsmin
        printf "dt=%d wall=%d cpupct=%.2f peak=%d\n", dt, wall, dt/clk/wall*100, peak
    }' "$R/samples/resources.csv"
