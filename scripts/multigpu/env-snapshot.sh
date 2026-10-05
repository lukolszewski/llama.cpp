#!/usr/bin/env bash
# Capture the hardware/topology/toolchain record for a benchmark machine.
#
# Fills in the TBD fields of benches/multi-gpu/<machine>/hardware.md with measured values, so that a
# benchmark result always comes with the topology that produced it. On this class of machine the
# PCIe link widths and the GPU-to-GPU path are not incidental detail: they are the condition the
# patches respond to.
#
# Usage: scripts/multigpu/env-snapshot.sh [OUTDIR]
#   sudo is only needed for PCIe capability registers (lspci -vv) and DIMM speed (dmidecode).

set -uo pipefail

OUT="${1:-.}"
mkdir -p "$OUT"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
FILE="$OUT/snapshot-${STAMP}.txt"

say() { printf '%s\n' "$*" | tee -a "$FILE"; }
sec() { say; say "### $*"; }
run() { say; say "\$ $*"; eval "$*" 2>&1 | tee -a "$FILE" || say "(command unavailable: $*)"; }

: > "$FILE"
say "# llama.cpp-multigpu environment snapshot"
say "# generated $(date -u --iso-8601=seconds) on $(hostname)"
say "# NOTE: PCIe link state is load dependent. GPUs idle in P8 report Gen1 and reduced width;"
say "#       re-run while a server is running to capture meaningful LnkSta values."

sec "system"
run "uname -a"
run "cat /etc/os-release | head -5"
run "uptime"

sec "cpu / numa"
run "lscpu"
run "lscpu | grep -E 'Model name|^CPU\(s\)|Socket|Core|Thread|NUMA'"
run "cat /sys/devices/system/node/possible 2>/dev/null"
command -v numactl > /dev/null 2>&1 && run "numactl --hardware"

sec "memory"
run "free -g"
run "cat /proc/meminfo | head -5"
if [ "$(id -u)" = "0" ]; then run "dmidecode -t memory | grep -E 'Size|Speed|Manufacturer|Part Number'"
else say "dmidecode skipped (needs sudo) - DIMM speed/config stays TBD"; fi

sec "motherboard"
for f in board_name board_vendor product_name bios_version bios_date sys_vendor; do
    v="$(cat "/sys/class/dmi/id/$f" 2>/dev/null || echo 'n/a')"
    say "$f: $v"
done

sec "gpu / driver"
command -v nvidia-smi > /dev/null 2>&1 || { say "nvidia-smi not found"; }
run "nvidia-smi"
run "nvidia-smi --query-gpu=index,name,driver_version,memory.total,memory.used,pci.bus_id,pcie.link.gen.current,pcie.link.width.current,power.limit,power.draw,temperature.gpu,clocks.sm,clocks.mem --format=csv"
run "nvidia-smi -q -d PCI,CLOCK,POWER,TEMPERATURE | head -120"
run "nvidia-smi topo -m"
run "nvidia-smi nvlink -s"

sec "pci topology"
run "lspci | grep -i nvidia"
if [ "$(id -u)" = "0" ]; then
    for d in $(lspci | awk '/NVIDIA|VGA|3D controller/{print $1}'); do
        say; say "\$ lspci -vv -s $d (LnkCap/LnkSta)"
        lspci -vv -s "$d" 2>/dev/null | grep -E 'LnkCap:|LnkSta:|Kernel driver' | tee -a "$FILE"
    done
    run "readlink /sys/bus/pci/devices/*/iommu_group 2>/dev/null | sort | uniq -c"
    say; say "\$ ACS / IOMMU groups"
    find /sys/kernel/iommu_groups -maxdepth 2 -name 'devices' 2>/dev/null | head -20 | tee -a "$FILE"
else
    say "lspci -vv capability registers need sudo - LnkCap/LnkSta stay TBD"
    say "idle link state (not capability):"
    for d in $(lspci | awk '/NVIDIA|3D controller/{print $1}'); do
        say "  $d: $(cat /sys/bus/pci/devices/$d/current_link_width 2>/dev/null)x width, gen $(cat /sys/bus/pci/devices/$d/current_link_speed 2>/dev/null), max $(cat /sys/bus/pci/devices/$d/max_link_width 2>/dev/null)x gen $(cat /sys/bus/pci/devices/$d/max_link_speed 2>/dev/null)"
    done
fi

sec "cuda toolkit / compiler"
run "command -v nvcc && nvcc --version"
run "ls -d /usr/local/cuda* 2>/dev/null"
run "cc --version | head -1"
run "cmake --version | head -1"
run "ninja --version 2>/dev/null"
run "docker --version 2>/dev/null"
run "ldconfig -p | grep -E 'libcuda\.so|libcudart|libcublas' | head"

sec "source revisions"
if git -C "$(dirname "$0")/../.." rev-parse HEAD > /dev/null 2>&1; then
    ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
    run "git -C $ROOT log -1 --format='multigpu HEAD: %H %cI' 2>/dev/null"
    run "git -C $ROOT rev-parse --abbrev-ref HEAD"
    for ref in refs/remotes/upstream/master refs/remotes/origin/master master; do
        base="$(git -C "$ROOT" merge-base HEAD "$ref" 2>/dev/null)" || continue
        say "upstream base via $ref: $base"
        git -C "$ROOT" log -1 --format='  %cI %s' "$base" | tee -a "$FILE"
        break
    done
fi

sec "running llama-server processes (configuration actually in use)"
run "ps -eo pid,etime,args | grep -E 'llama-server|llama-cli' | grep -v grep | head"
run "tr '\0' ' ' < /proc/$(pgrep -f 'llama-server' | head -1)/environ 2>/dev/null | tr ' ' '\n' | grep -E '^(LLAMA|GGML)_' | head -20"

sec "model files"
run "find / -maxdepth 4 -name 'Qwen3.8-Flash-Next*.gguf' 2>/dev/null | head"

say
say "# Snapshot written to $FILE"
say "# Copy the measured values into benches/multi-gpu/<machine>/hardware.md and mark anything still"
say "# unmeasured as TBD rather than estimating."
