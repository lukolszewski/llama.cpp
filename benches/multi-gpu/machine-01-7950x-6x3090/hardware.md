# machine-01 — AMD Ryzen 9 7950X + 6 x RTX 3090 (constrained PCIe)

Primary benchmark machine, hostname `megaczop`. This is the topology the fork exists for: several
consumer GPUs sharing constrained PCIe links, with only GPUs 0/1 additionally bridged by NVLink.

Values below were read from the machine on **2026-10-04**. `TBD` = not measured. Regenerate with
`scripts/multigpu/env-snapshot.sh` (some fields need `sudo`).

## System

| field | value | source |
| --- | --- | --- |
| OS | Debian GNU/Linux 12 (bookworm) | `/etc/os-release` |
| Kernel | `6.12.9 #2 SMP PREEMPT_DYNAMIC Mon Jan 13 13:07:46 CET 2025 x86_64` (custom build) | `uname -a` |
| CPU | AMD Ryzen 9 7950X 16-Core Processor, 32 logical CPUs | `lscpu` |
| NUMA | 1 NUMA node exposed, GPU affinity 0-31 on all devices | `lscpu`, `nvidia-smi topo -m` |
| RAM | 192 GB DDR5, 4 x 48 GB, JEDEC speed settings (`free` reports 187 GiB total) | brief + `free -g`; module speed TBD (`dmidecode -t memory` needs root) |
| Motherboard | ASUS ProArt X670E-CREATOR WIFI (ASUSTeK COMPUTER INC.) | `/sys/class/dmi/id/board_name` |
| NVIDIA driver | 595.99.02 | `nvidia-smi` |
| Driver-reported CUDA | 13.2 | `nvidia-smi` |
| CUDA toolkit / `nvcc` | TBD — no `nvcc` on `PATH` at snapshot time; Docker 20.10.24 present | `command -v nvcc`, `docker --version` |
| Compiler / CMake / Ninja | TBD | |
| Persistence mode | Off on all GPUs | `nvidia-smi` |
| Power cap / cooling | 300 W limit per 3090 as reported; airflow and thermal policy TBD | `nvidia-smi` |

## GPUs

| index | model | VRAM | PCI bus id | PCIe width (idle) | PCIe gen (idle) | NVLink |
| --- | --- | --- | --- | --- | --- | --- |
| 0 | GeForce RTX 3090 | 24576 MiB | `00000000:01:00.0` | x8 | Gen1 (P8 idle) | 4 links, NV4 to GPU1 |
| 1 | GeForce RTX 3090 | 24576 MiB | `00000000:03:00.0` | x8 | Gen1 (P8 idle) | 4 links, NV4 to GPU0 |
| 2 | GeForce RTX 3090 | 24576 MiB | `00000000:12:00.0` | x4 | Gen1 (P8 idle) | no active links |
| 3 | GeForce RTX 3090 | 24576 MiB | `00000000:16:00.0` | x2 | Gen1 (P8 idle) | no active links |
| 4 | GeForce RTX 3090 | 24576 MiB | `00000000:3e:00.0` | x4 | Gen1 (P8 idle) | no active links |
| 5 | GeForce RTX 3090 | 24576 MiB | `00000000:42:00.0` | x4 | Gen1 (P8 idle) | no active links |
| 6 | GeForce RTX 5060 Ti | 16311 MiB | `00000000:68:00.0` | x2 | Gen4 | n/a |

**Aggregate 3090 VRAM: 144 GB.** The RTX 5060 Ti is present in the machine, at ~208 MiB used at
snapshot time with an X server running on `:0`; it is treated as the display GPU and is **not** part of
the 6-GPU inference pool. Whether it participates in any measurement is therefore `TBD`, and results
that involve it must say so explicitly.

### Interconnect

`nvidia-smi topo -m` (2026-10-04):

| | GPU0 | GPU1 | GPU2 | GPU3 | GPU4 | GPU5 | GPU6 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| GPU0 | X | NV4 | PHB | PHB | PHB | PHB | PHB |
| GPU1 | NV4 | X | PHB | PHB | PHB | PHB | PHB |
| GPU2 | PHB | PHB | X | PXB | PXB | PXB | PXB |
| GPU3 | PHB | PHB | PXB | X | PXB | PXB | PXB |
| GPU4 | PHB | PHB | PXB | PXB | X | PXB | PXB |
| GPU5 | PHB | PHB | PXB | PXB | PXB | X | PXB |
| GPU6 | PHB | PHB | PXB | PXB | PXB | PXB | X |

`PHB` = traversal through a PCIe host bridge (i.e. through the CPU), `PXB` = through PCIe bridges
within the host. Practically: most GPU-to-GPU traffic on this machine crosses the PCIe host bridge
rather than a dedicated high-bandwidth link, and GPUs 2-5 sit on reduced-width links (x4, x2, x4, x4).
This is the condition that makes several llama.cpp behaviours expensive here and not elsewhere.

| field | value |
| --- | --- |
| NVLink between GPU0/GPU1 | 4 active links, 14.062 GB/s each (`nvidia-smi nvlink -s`) |
| PCIe capability (LnkCap) per slot | TBD — needs `sudo lspci -vv` |
| PCIe negotiated state under load (LnkSta) | TBD — the idle readings above are P8 power-state artifacts and must not be quoted as link capability |
| ACS / IOMMU groups | TBD |
| P2P availability between the 3090s | TBD |

## Model under test

| field | value |
| --- | --- |
| Model | Qwen3.8-Flash-Next |
| llama.cpp architecture | `qwen4exp` (`LLM_ARCH_QWEN4EXP`) — an upstream llama.cpp architecture, not a fork addition |
| Source | `unsloth/Qwen3.8-Flash-Next-GGUF` (base model `Qwen/Qwen3.8-Flash-Next`) |
| Quantization | `UD-Q4_K_XL` |
| Files | `Qwen3.8-Flash-Next-UD-Q4_K_XL-00001-of-00004.gguf` (10.9 MB) <br> `-00002-of-00004.gguf` (49.86 GB) <br> `-00003-of-00004.gguf` (49.38 GB) <br> `-00004-of-00004.gguf` (12.09 GB) |
| Total weights | ~111.3 GB |
| Weights vs VRAM | ~111.3 GB of weights in 144 GB aggregate VRAM → roughly 33 GB left for KV cache and compute buffers across all six devices, before allocation overhead. Measured per-device usage: TBD |
| MTP drafts (`MTP/mtp-Qwen3.8-Flash-Next-*.gguf`) | **out of scope** — little benefit in the single-user case, and they cost throughput in the multi-slot case, which is the opposite of what this fork optimizes |
| Other quants in the repo (`Q8_0`, `BF16`, `UD-Q2_K_XL`, `UD-Q3_K_XL`, `UD-IQ4_XS`, …) | available, **not benchmarked** |

## Server configuration under test

Recorded per run; none of it is fixed by this document, and nothing here may be quoted as a result.

| field | value |
| --- | --- |
| llama.cpp upstream commit | TBD |
| multigpu commit | TBD |
| build flags / CUDA version | TBD (see `BUILD_INFO.json` of the artifact used) |
| command line | TBD |
| `-np` slots | 5 (benchmark server configuration); 1 for the single-slot suite |
| `--ctx-size` | TBD per run (5k / 50k / 150k / 200k / 250k suite) |
| `-b` / `-ub` batch and microbatch | TBD |
| `-sm` split mode / tensor split | TBD |
| `-ngl` | TBD (expected: all layers offloaded) |
| `-fa` flash attention | TBD |
| KV cache type | TBD (relevant to patch 2, which exists so quantized KV keeps the sparse speedup) |
| `graph` reuse / CUDA graphs | TBD |
| environment variables | TBD — required, since this patchset is switch-selected (see patches.md) |

## Benchmarks recorded here

**None yet.** No results have been measured. The table structure lives in
[`docs/multigpu/benchmarks.md`](../../../docs/multigpu/benchmarks.md) with every value `TBD`; this
directory will hold the raw JSON/logs once `scripts/multigpu/bench/` runs are executed.
