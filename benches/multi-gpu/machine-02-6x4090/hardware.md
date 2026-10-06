# machine-02-6x4090 — Intel(R) Xeon(R) Platinum 8352V CPU @ 2.10GHz + 8 x NVIDIA GeForce RTX 4090 (rented, Vast.ai)

Read from inside the benchmark container on **2026-10-06** by `scripts/multigpu/bench/vast/collect-hardware.py`.
`TBD` = not readable from a container without root (PCIe capability registers, motherboard, RAM modules).
Everything else is the driver's own report. Vast.ai machine/instance ids are in `hardware.json`.

## System

| field | value | source |
| --- | --- | --- |
| Host | Vast.ai rental, machine id TBD, instance C.54517556 | environment |
| Container OS | Ubuntu 24.04.2 LTS (host OS not visible) | `/etc/os-release` |
| Kernel | `5.15.0-186-generic` | `uname -r` |
| CPU | Intel(R) Xeon(R) Platinum 8352V CPU @ 2.10GHz, 144 logical CPUs, 2 socket(s), AVX-512 yes | `lscpu` |
| NUMA | 2 node(s) | `lscpu` |
| RAM | 755.2 GiB visible (cgroup limit 696314232832); modules/speed TBD | `/proc/meminfo` |
| Motherboard | TBD (no DMI access in the container) | |
| NVIDIA driver | 570.211.01 | `nvidia-smi` |
| Driver-reported CUDA | 12.8 | `nvidia-smi` |
| Binaries | `BUILD_INFO.json` in the run directory (CUDA toolkit, SASS/PTX list, commits) | image |

## GPUs

| index | model | VRAM | compute cap. | PCI bus id | PCIe gen (max/current) | PCIe width (max/current) | power limit | ECC |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 0 | NVIDIA GeForce RTX 4090 | 24564 MiB | 8.9 | `00000000:17:00.0` | 4/4 | 16/8 | 450.00 W | Disabled |
| 1 | NVIDIA GeForce RTX 4090 | 24564 MiB | 8.9 | `00000000:18:00.0` | 4/4 | 16/8 | 450.00 W | Disabled |
| 2 | NVIDIA GeForce RTX 4090 | 24564 MiB | 8.9 | `00000000:31:00.0` | 4/4 | 16/8 | 450.00 W | Disabled |
| 3 | NVIDIA GeForce RTX 4090 | 24564 MiB | 8.9 | `00000000:32:00.0` | 3/3 | 16/8 | 450.00 W | Disabled |
| 4 | NVIDIA GeForce RTX 4090 | 24564 MiB | 8.9 | `00000000:65:00.0` | 4/4 | 16/4 | 450.00 W | Disabled |
| 5 | NVIDIA GeForce RTX 4090 | 24564 MiB | 8.9 | `00000000:66:00.0` | 4/4 | 16/8 | 450.00 W | Disabled |
| 6 | NVIDIA GeForce RTX 4090 | 24564 MiB | 8.9 | `00000000:98:00.0` | 4/1 | 16/8 | 450.00 W | Disabled |
| 7 | NVIDIA GeForce RTX 4090 | 24564 MiB | 8.9 | `00000000:99:00.0` | 4/1 | 16/8 | 450.00 W | Disabled |

**Aggregate VRAM: 196512 MiB (192 GiB).** PCIe gen/width "current" is what the driver
reported at collection time (idle GPUs often sit at Gen1 in P8; the "max" column is the link capability).

### Interconnect

`nvidia-smi topo -m`:

```
	[4mGPU0	GPU1	GPU2	GPU3	GPU4	GPU5	GPU6	GPU7	CPU Affinity	NUMA Affinity	GPU NUMA ID[0m
GPU0	 X 	PHB	NODE	NODE	NODE	NODE	SYS	SYS	0-35,72-107	0		N/A
GPU1	PHB	 X 	NODE	NODE	NODE	NODE	SYS	SYS	0-35,72-107	0		N/A
GPU2	NODE	NODE	 X 	PHB	NODE	NODE	SYS	SYS	0-35,72-107	0		N/A
GPU3	NODE	NODE	PHB	 X 	NODE	NODE	SYS	SYS	0-35,72-107	0		N/A
GPU4	NODE	NODE	NODE	NODE	 X 	PHB	SYS	SYS	0-35,72-107	0		N/A
GPU5	NODE	NODE	NODE	NODE	PHB	 X 	SYS	SYS	0-35,72-107	0		N/A
GPU6	SYS	SYS	SYS	SYS	SYS	SYS	 X 	PHB	36-71,108-143	1		N/A
GPU7	SYS	SYS	SYS	SYS	SYS	SYS	PHB	 X 	36-71,108-143	1		N/A

Legend:

  X    = Self
  SYS  = Connection traversing PCIe as well as the SMP interconnect between NUMA nodes (e.g., QPI/UPI)
  NODE = Connection traversing PCIe as well as the interconnect between PCIe Host Bridges within a NUMA node
  PHB  = Connection traversing PCIe as well as a PCIe Host Bridge (typically the CPU)
  PXB  = Connection traversing multiple PCIe bridges (without traversing the PCIe Host Bridge)
  PIX  = Connection traversing at most a single PCIe bridge
  NV#  = Connection traversing a bonded set of # NVLinks
```
