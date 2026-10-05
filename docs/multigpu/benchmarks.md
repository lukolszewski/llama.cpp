# Benchmark methodology and results

Benchmarks are the reason this fork exists: a performance claim without a measured number, a named
upstream revision and a named machine is not a result. **No results are published yet.** The structure
below is what future numbers will fill in; every `TBD` means "not measured", never "approximately".

- Headline table: [README §4](../../README.md#4-performance-summary)
- This document: suites, protocol, metric definitions, machine records, reproduction steps
- Raw output: `benches/multi-gpu/<machine>/`

---

## Rules

1. **Every comparison names both revisions.** `upstream commit: <sha>` and `multigpu commit: <sha>`.
   Saying "upstream" without a revision is meaningless because llama.cpp moves daily. If an upstream
   change removes a patch's benefit, that must be visible, and the patch gets dropped
   ([patches.md#removal-criteria](patches.md#removal-criteria)).
2. **Every number names its machine and its configuration**: model + quant + file list, context size,
   slot count, batch settings, split mode / tensor split, GPU placement, environment variables, server
   command line, CUDA/driver/toolchain, build flags.
3. **Never mix machines in one table.** A row belongs to exactly one machine record. Cross-machine
   comparison is done by linking two tables, not by merging rows.
4. **No fabricated or interpolated values.** Missing data stays `TBD`.
5. **Unfavourable behaviour is published.** Mixed prefill + generation is documented as its own section
   rather than hidden behind all-prefill / all-generate tables.
6. **A patch may be a net loss elsewhere.** Each result states the tested hardware and workload; claims
   beyond that configuration are not made.

---

## Machines

### machine-01 (primary)

| field | value | source |
| --- | --- | --- |
| hostname | `megaczop` | measured 2026-10-04 |
| CPU | AMD Ryzen 9 7950X, 16C/32T, 1 NUMA node exposed | `lscpu` |
| RAM | 192 GB DDR5, 4 x 48 GB, JEDEC settings (`free` reports 187 GiB) | brief + `free -g` |
| Motherboard | ASUS ProArt X670E-CREATOR WIFI | `/sys/class/dmi/id/board_name` |
| GPUs | 6 x GeForce RTX 3090, 24576 MiB each, 144 GB aggregate | `nvidia-smi` |
| Other GPU | 1 x GeForce RTX 5060 Ti, 16311 MiB (index 6, ~208 MiB used, not in the inference pool) | `nvidia-smi` |
| GPU 0/1 interconnect | NVLink, 4 active links at 14.062 GB/s each (`NV4` in `nvidia-smi topo -m`) | `nvidia-smi nvlink -s`, `topo -m` |
| GPU 2-5 interconnect | `PHB`/`PXB` — behind PCIe host bridges, no active NVLink | `nvidia-smi topo -m` |
| PCIe width per GPU (idle) | GPU0 x8, GPU1 x8, GPU2 x4, GPU3 x2, GPU4 x4, GPU5 x4 | `nvidia-smi --query-gpu=pcie.link.width.current` |
| PCIe generation (idle) | Gen1 reported for all 3090s while in P8 — a power-state artifact, **not** the link capability | `nvidia-smi --query-gpu=pcie.link.gen.current` |
| PCIe LnkCap / LnkSta under load | **TBD** (needs `sudo lspci -vv` while the GPUs are busy) | `scripts/multigpu/env-snapshot.sh` |
| OS / kernel | Debian GNU/Linux 12 (bookworm), 6.12.9 SMP PREEMPT_DYNAMIC | `uname -a` |
| NVIDIA driver | 595.99.02, driver-reported CUDA 13.2 | `nvidia-smi` |
| CUDA toolkit / `nvcc` on host | **TBD** (no `nvcc` in `PATH` at snapshot time) | `command -v nvcc` |
| Compiler / toolchain | **TBD** | |
| CMake / Ninja | **TBD** | |
| ECC / power limits / cooling | **TBD** (3090 has no ECC; power caps affect every number here) | |
| Model | Qwen3.8-Flash-Next, GGUF arch `qwen4exp` | |
| Quantization | `UD-Q4_K_XL` from `unsloth/Qwen3.8-Flash-Next-GGUF` | |
| Model files | `Qwen3.8-Flash-Next-UD-Q4_K_XL-00001-of-00004.gguf` (10.9 MB), `-00002-of-00004.gguf` (49.86 GB), `-00003-of-00004.gguf` (49.38 GB), `-00004-of-00004.gguf` (12.09 GB) — ~111.3 GB total | HF API listing |
| VRAM budget | 144 GB aggregate − ~111.3 GB weights ≈ 33 GB for KV cache + compute buffers across 6 devices, before overhead; measured per-device usage **TBD** | arithmetic on the two rows above |
| Server command line | **TBD (recorded per run)** | |
| Slots / context / batch / split mode | **TBD** (`-np 5` is the benchmark server configuration) | |
| Environment variables | **TBD** (must be recorded, since the patchset is switch-selected) | |

Regenerate this record with `scripts/multigpu/env-snapshot.sh`, which writes the raw tool output to
`benches/multi-gpu/machine-01-7950x-6x3090/`. Fields marked **TBD** require either root (PCIe
capability registers) or a run of the benchmark itself.

### machine-02, machine-03 (reserved, not yet used)

Rented multi-GPU comparisons are planned, likely multi-RTX-4090 and/or multi-RTX-5090. Each gets its
own directory and its own field table in the same format as machine-01. Until a machine exists and has
run the suite, it has no rows anywhere — no placeholder numbers.

| machine | GPUs | status |
| --- | --- | --- |
| machine-02 | TBD (candidate: multiple RTX 4090) | not provisioned; all results TBD |
| machine-03 | TBD (candidate: multiple RTX 5090 / `sm_120`) | not provisioned; all results TBD |

A note for future machines: `sm_120` hardware also lets us runtime-validate the `120a` build, which
machine-01 cannot do for its `sm_89`/`sm_120a` artifacts (its 5060 Ti is `sm_120` but is the display
GPU and outside the inference pool).

---

## Suites

### Single slot (`-np 1`, one active session)

For each context/prompt size **5k, 50k, 150k, 200k, 250k**:

1. **prefill / prompt processing** — the whole prompt processed as one request;
2. **generation** — decode from the resulting context.

Purpose: characterize a single interactive session from short prompts up to very large contexts, where
KV cache growth and cross-device traffic begin to dominate.

### Five slots (`-np 5`, all slots active concurrently)

For each of the same sizes, all five slots concurrently, as two separate workloads:

1. **all five prefill at once**;
2. **all five generate at once**.

Both aggregate throughput and per-slot throughput are reported: a 5x aggregate figure with 5x worse
per-slot latency is not a win for the intended user.

Why 5 slots: that is the benchmark server configuration, and it matches the intended usage — one
person running several agent sessions, coding-agent tasks, independent chats or parallel research
jobs against a single local server.

---

## Metrics

| metric | definition |
| --- | --- |
| prompt processing t/s | tokens/sec over the whole prefill, from request start to first token generated |
| generation t/s | decode tokens/sec, averaged over the measured generation window |
| aggregate t/s | sum across all concurrently active slots |
| per-slot t/s | mean over slots, plus min/max if spread matters |
| time to first token | request received → first token emitted, per slot |
| total prefill time | wall-clock until the last slot finished prefilling |
| total generation wall time | wall-clock for the whole generation window |
| per-request latency | end-to-end per request, including queueing/waiting |
| VRAM per device | `nvidia-smi` sampled during the run, peak and steady-state |
| host RAM | peak RSS of the server process |
| GPU utilization | optional, `nvidia-smi`/DCGM if reproducible |
| PCIe traffic | optional, only if a reproducible measurement method is documented |

The README carries only the headline table; the rest lives here and in `benches/multi-gpu/`.

---

## Results

### machine-01

```
upstream commit:  TBD (<sha>)
multigpu commit:  TBD (<sha>)
model:            Qwen3.8-Flash-Next, UD-Q4_K_XL
```

| Workload | Context | Upstream llama.cpp | llama.cpp-multigpu | Improvement |
| --- | --- | --- | --- | --- |
| 1 slot - prefill | 5k | TBD | TBD | TBD |
| 1 slot - generate | 5k | TBD | TBD | TBD |
| 1 slot - prefill | 50k | TBD | TBD | TBD |
| 1 slot - generate | 50k | TBD | TBD | TBD |
| 1 slot - prefill | 150k | TBD | TBD | TBD |
| 1 slot - generate | 150k | TBD | TBD | TBD |
| 1 slot - prefill | 200k | TBD | TBD | TBD |
| 1 slot - generate | 200k | TBD | TBD | TBD |
| 1 slot - prefill | 250k | TBD | TBD | TBD |
| 1 slot - generate | 250k | TBD | TBD | TBD |
| 5 slots - concurrent prefill | 5k | TBD | TBD | TBD |
| 5 slots - concurrent generate | 5k | TBD | TBD | TBD |
| 5 slots - concurrent prefill | 50k | TBD | TBD | TBD |
| 5 slots - concurrent generate | 50k | TBD | TBD | TBD |
| 5 slots - concurrent prefill | 150k | TBD | TBD | TBD |
| 5 slots - concurrent generate | 150k | TBD | TBD | TBD |
| 5 slots - concurrent prefill | 200k | TBD | TBD | TBD |
| 5 slots - concurrent generate | 200k | TBD | TBD | TBD |
| 5 slots - concurrent prefill | 250k | TBD | TBD | TBD |
| 5 slots - concurrent generate | 250k | TBD | TBD | TBD |

Units: tokens/s (aggregate for the 5-slot rows; per-slot values recorded alongside). Improvement is
reported as a ratio **and** absolute delta, since a 2x on a bad baseline and a 1.2x on a good one mean
different things to different users.

### machine-02 / machine-03

Same table shape, all `TBD`, no rows until the machines exist.

---

## Mixed workload behavior

Not part of the headline table, and not to be inferred from it.

When prompt prefill happens while another slot is generating, the two interfere: the prefill's large
batch competes with decode's latency-critical small batch, and on this hardware they also contend for
the same constrained PCIe links that the scheduler uses to move activations between GPUs. The current
result is less-than-ideal behaviour for that mixture, which is exactly why the fork is presented as
**multi-session single-user** tooling rather than a general multi-tenant inference server.

Consequences to state whenever results are published:

- all-prefill and all-generate numbers are best-case slices of the workload;
- a user whose requests arrive continuously and expect consistent latency should not read the headline
  table as their expectation;
- the admission-control patches (`--prefill-max-partial`, `--prefill-max-long`) are the current
  mitigation, i.e. they bound interference by making some slots wait, which trades throughput for
  predictability. Their effect is itself a measurement to be published, **TBD**.

Planned but **not implemented** — deliberately no suite, no scripts and no rows until they exist:

- one generating slot + one prefilling slot;
- several generating slots + one prefilling slot;
- continuous arrival mix.

---

## Reproducing

```sh
# 1. build or download BOTH revisions. Record the two commits.
#    upstream:   master @ <sha>          (stock build, no downstream switches)
#    multigpu:   multigpu @ <sha>

# 2. capture the machine record on the benchmark box (needs sudo for PCIe registers)
scripts/multigpu/env-snapshot.sh benches/multi-gpu/machine-01-7950x-6x3090

# 3. single-slot suite (prefill + generate at 5k/50k/150k/200k/250k)
scripts/multigpu/bench/run-single-slot.sh --model <first-shard.gguf> --out results.json

# 4. five-slot suite against a running server (-np 5), all-prefill and all-generate
scripts/multigpu/bench/run-5-slot.py --server http://127.0.0.1:8080 --slots 5 --size 50000 --phase pp

# 5. paste the resulting table rows here, plus the raw files into benches/multi-gpu/<machine>/
```

The scripts in `scripts/multigpu/bench/` implement the protocol above. **They have not been executed
yet**, so treat them as unverified until a first run; report problems, do not quietly adjust the
protocol afterwards. Each run must print both commit hashes into its output file so a stray JSON blob
can still be attributed.

For comparisons against upstream, run the same script twice with different `--bin` values, on the same
machine, same model file, same session, ideally back-to-back to keep thermal state comparable. Record
GPU temperatures/power caps if they plausibly affect the numbers — on air-cooled 3090s they do.
