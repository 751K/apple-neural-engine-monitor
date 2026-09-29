#!/usr/bin/env python3
"""Pairs ANE task events in ktrace text output and reports task durations.

Firmware events 0x061b0125 (start) / 0x061b0126 (end) are matched on
(program handle arg1, transaction id arg3); host events 0x061b00a0 carry
arg1 = 0 (submit) or 1 (complete) and match on arg4.

usage: trace_pairs.py TRACE.txt...
"""
import sys


def ts_us(field):
    h, m, s = field.split(":")
    return (int(h) * 3600 + int(m) * 60 + float(s)) * 1e6


for path in sys.argv[1:]:
    fw_start, host_start = {}, {}
    fw, host, ends, txn_gaps, prev_txn = [], [], 0, 0, {}
    for line in open(path, errors="replace"):
        p = line.split()
        if len(p) < 10:
            continue
        t, code = ts_us(p[1]), p[4]
        if code == "61b0125":
            fw_start[(p[5], p[7])] = t
        elif code == "61b0126":
            ends += 1
            txn = int(p[7], 16)
            if p[5] in prev_txn and txn != prev_txn[p[5]] + 1:
                txn_gaps += 1
            prev_txn[p[5]] = txn
            if (p[5], p[7]) in fw_start:
                fw.append(t - fw_start.pop((p[5], p[7])))
        elif code == "61b00a0":
            if p[5] == "0":
                host_start[p[8]] = t
            elif p[8] in host_start:
                host.append(t - host_start.pop(p[8]))
    mean = lambda v: sum(v) / len(v) if v else float("nan")
    print(f"{path}: {ends} firmware task ends, {len(fw)} with a start event, "
          f"{txn_gaps} txn gaps; firmware task {mean(fw):.1f} us, host submit→complete {mean(host):.1f} us")
