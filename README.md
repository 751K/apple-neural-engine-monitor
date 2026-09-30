# Apple Neural Engine Monitor (anemon)

A terminal monitor for the Apple Neural Engine (ANE) on Apple Silicon Macs.
It shows how much of the time the ANE is executing work, which processes are
using it, how much memory traffic it generates and how much power it draws.

```
make
sudo .build/make/anemon calibrate   # once per machine, about 2 min
sudo .build/make/anemon             # full-screen view, q to quit
sudo .build/make/anemon --json      # one JSON object per interval
     .build/make/anemon --json      # without root: DRAM, interrupts and, on M6, power
```

Options: `--interval SECONDS` (default 1), `--count N`, `--no-power`.

`make` builds `anemon` and `anebench`, a small tool that generates convolution
models and runs them on the ANE; calibration uses it for its test workloads.

## What it reports

| Metric | Meaning | Needs root |
|---|---|---|
| busy % | Share of wall time the ANE was executing a task | yes |
| tasks/s, ms/task | Completed ANE tasks and their mean duration | yes |
| programs | Busy time and task rate per compiled model, with the process (name and PID) that submits it | yes |
| power | ANE power | M4: yes. M6: no |
| DRAM read/write | ANE traffic to memory | no |
| interrupts | ANE interrupt rate | no |

**busy % is time occupancy, not compute utilization.** Like the GPU "active"
figure, it says whether the ANE had work, not how much of its arithmetic was
in use. A metric that is unavailable on a chip is reported as null, never as 0.

## Supported chips

| | M4 | M6 (macOS 27.0.1) |
|---|---|---|
| busy %, tasks, programs | validated | busy check passed |
| DRAM | exact | lower bound at full speed |
| power | from `powermetrics` | estimate |

On M4, DRAM works with SIP enabled and without root.

**After the Mac has slept, busy % is less precise until the next reboot.**
macOS stops delivering the ANE's own task events after sleep, and anemon falls
back to the driver's events: busy % stays within about 1.5 points, but on M6
tasks/s doubles and the two engines can no longer be told apart. JSON reports
`slept_since_boot_s`. On a benchmark machine, disable sleep or reboot first.

Other chips: run `sudo anemon calibrate` to check busy %. DRAM and power stay
null until a chip has been characterized. These are private macOS interfaces
and may change between releases.

## JSON output

Each line is one interval. Besides the metrics above:

| Field | Values |
|---|---|
| `ane_busy_source` | `firmware` (ANE task events), `host` (driver events, includes queueing) or `none` |
| `ane_busy_status` | `measured`, `idle`, `unverified` or `unsupported` (ANE active but no task events; `ane_busy_pct` is then null) |
| `programs` | Up to 16 entries: `handle`, `pid`, `process`, `tasks`, `busy_ms` |
| `ane_power_source` | `powermetrics` or `smc_estimate` |
| `dram_source` | `amc` (byte counters) or `histogram` |
| `dram_clipped_pct` | Share of samples at the top of the histogram range; above 10% the reading is a lower bound |
| `slept_since_boot_s` | Time the Mac has slept since boot |
| `validated` | The busy check has passed for this chip and macOS major version |
| `calibrated` | A calibration profile exists for this machine |

## Calibration

`sudo anemon calibrate` runs reference workloads for about two minutes (close
other ANE and GPU work first). It measures idle and peak ANE power, peak INT8
throughput and read bandwidth, and checks busy % against the host at 100% and
50% duty; the check passes within 5 points. The profile is saved to
`/Library/Application Support/anemon/<architecture>.json` and sets the scale of
the power and DRAM bars.

## Validation

### M4

busy % against the share of wall time spent in the ANE on the host:

| Workload | Host | anemon |
|---|---|---|
| idle | 0% | 0.0% |
| 10 ms tasks, continuous | 100% | 98.3–98.8% |
| 10 ms tasks, 50% duty | 51.4% | 50.9% |
| 10 ms tasks, 25% duty | 26.7% | 26.8% |
| 42 ms tasks, continuous | 100% | 99.5% |
| 5–8 ms tasks, 50% duty | 53.8% | 51.1% |
| 18.6 ms tasks, 50% duty (macOS 27.0.1) | 53.9% | 54.4% |
| 10.7 ms tasks, 50% duty, after sleep | 50.8% | 51.1% |

- Two processes sharing the ANE: 100% busy, no task events lost, each attributed to its own PID.
- Peak INT8 throughput 35–38 TOPS across runs (theoretical 38.4).
- Power 0.66 W with tiny tasks, 2.1–2.6 W for FP16 convolutions, 3.4–4.1 W for INT8.
- Read bandwidth 66 GB/s, matching the weight traffic of the test GEMV.
- A MacBook Air M4 with SIP enabled gave the same results.

### M6

| Workload | Host | anemon |
|---|---|---|
| 10.3 ms tasks, continuous | 100% | 96.5% |
| 10.3 ms tasks, 50% duty | 48.8% | 48.3% |
| two processes, 3.9 ms tasks | 100% | 99.9–100% |

- Two processes: task events lost dropped from about 10% to 0.1%, and each program was attributed to its PID.
- Peak INT8 throughput 75.9 TOPS.
- DRAM against the weight traffic of an FP16 GEMV:

| Duty | Weight traffic | anemon |
|---:|---:|---:|
| 100% | 133.5 GB/s | 115 GB/s (lower bound) |
| 50% | 59.8 GB/s | 50–55 GB/s |
| 25% | 28.1 GB/s | 25 GB/s |

- Power: an INT8 convolution load read 5.0–5.4 W against a 5.3 W rise in the
  supply rail, and returned to 0 within two seconds. Not yet checked with a
  real model.

## Limitations

- While anemon runs, Instruments, `ktrace` and `fs_usage` cannot trace, and
  anemon cannot start while one of them is tracing.
- Programs are shown by process, not by model name.
- Compute utilization is not available: the ANE's performance counters go only
  to the process that submitted the work, and even root cannot read them for
  other processes.
- On M6 both engines have always run the same work in lockstep; separate
  workloads on the two engines have not been tested.

## Repository

- `Sources/anemon`: the monitor (Swift).
- `Sources/CANEMon`: kdebug, IOReport and SMC readers (C).
- `Sources/anebench`, `Sources/CANERun`: the workload generator and runner.
- [`calibration/`](calibration/): how each metric is read, and the
  measurements and scripts behind it.

## License

MIT. See [LICENSE](LICENSE).
