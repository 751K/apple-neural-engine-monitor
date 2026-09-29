#!/usr/bin/env python3
"""Averages ANE/CPU power per workload from power.sh output. usage: power_report.py DIR"""
import os, re, sys, statistics as st
d = sys.argv[1]
print(f"{'workload':34}{'ANE W (avg)':>12}{'ANE W (max)':>12}{'CPU W':>8}{'ms/eval':>9}")
for f in sorted(os.listdir(d), key=lambda x: (x != "idle.txt", x)):
    if not f.endswith(".txt"): continue
    t = open(os.path.join(d, f)).read()
    ane = [int(x) for x in re.findall(r"ANE Power: (\d+) mW", t)]
    cpu = [int(x) for x in re.findall(r"CPU Power: (\d+) mW", t)]
    log = os.path.join(d, f[:-4] + ".log")
    ms = re.search(r"([\d.]+) ms/eval", open(log).read()).group(1) if os.path.exists(log) else "-"
    if ane: print(f"{f[:-4]:34}{st.mean(ane)/1000:>12.2f}{max(ane)/1000:>12.2f}{st.mean(cpu)/1000:>8.2f}{ms:>9}")
