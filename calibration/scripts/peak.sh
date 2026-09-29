#!/bin/bash
# Sustained INT8 (W8A8) conv throughput, MACs counted exactly by anebench gen.
# usage: peak.sh C HW K LAYERS PAD [SECONDS]     PAD same | valid
#   peak.sh 1024 128 5 8 same    -> 38.2 TOPS on M4
source "$(dirname "$0")/env.sh"
d=$MODELS/peak_C$1_HW$2_k$3_L$4_$5
if [ ! -f "$d/macs" ]; then
  PAD=$5 LAYERS=$4 "$ANEBENCH" gen "$d" a8w8 conv $1 $1 $2 $2 $3 > "$d.macs" && mv "$d.macs" "$d/macs" || exit 1
fi
macs=$(cat "$d/macs")
r=$("$ANEBENCH" run "$d" -t "${6:-5}" 2>&1) || { echo "C$1 HW$2 k$3 L$4 $5 FAIL: $(echo $r | cut -c1-90)"; exit 1; }
ms=$(grep -o '[0-9.]* ms/eval' <<<"$r" | cut -d' ' -f1)
awk -v c=$1 -v h=$2 -v k=$3 -v L=$4 -v p=$5 -v macs=$macs -v ms=$ms 'BEGIN{
  t=2*macs/(ms*1e-3)/1e12
  printf "k%d C%-5d HW%-4d L%-2d %-5s %8.1fG MAC %9.3f ms  %5.1f TOPS (%.1f%% of 38.4)\n",k,c,h,L,p,macs/1e9,ms,t,100*t/38.4}'
