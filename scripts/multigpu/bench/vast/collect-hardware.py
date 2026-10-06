#!/usr/bin/env python3
"""Machine record for a benchmark run, in the format of benches/multi-gpu/machine-01-*/hardware.md.

    collect-hardware.py OUT_DIR [--machine-name NAME]

Writes OUT_DIR/hardware.json (everything we could read) and OUT_DIR/hardware.md (the README §2 table shape).
Runs without root inside a container: nvidia-smi (driver, VRAM, PCIe link state as the driver reports it,
topology matrix), lscpu, /proc/meminfo, df, uname, /etc/os-release, lspci if the bus is visible, and the
Vast.ai environment variables if present. A field that cannot be read is written as "TBD", never guessed.
"""
import json, os, re, subprocess, sys, time

def run(cmd, timeout=60):
    try:
        p = subprocess.run(cmd, shell=isinstance(cmd, str), capture_output=True, text=True, timeout=timeout)
        return p.stdout if p.returncode == 0 else ""
    except Exception:
        return ""

def tbd(v):
    return v if v not in (None, "", "[N/A]", "N/A") else "TBD"

def main():
    if len(sys.argv) < 2:
        print(__doc__); sys.exit(2)
    out = sys.argv[1]; os.makedirs(out, exist_ok=True)
    name = sys.argv[sys.argv.index("--machine-name") + 1] if "--machine-name" in sys.argv else os.environ.get("MACHINE_NAME", "TBD")

    hw = {"collected_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "machine_name": name,
          "vast": {k: v for k, v in os.environ.items() if k.startswith(("VAST_", "CONTAINER_ID", "PUBLIC_IP", "GPU_COUNT"))}}

    # --- GPUs ---------------------------------------------------------------------
    q = ("index,name,memory.total,compute_cap,driver_version,pci.bus_id,pcie.link.gen.max,pcie.link.gen.current,"
         "pcie.link.width.max,pcie.link.width.current,power.limit,persistence_mode,ecc.mode.current")
    gpus = []
    for line in run(["nvidia-smi", f"--query-gpu={q}", "--format=csv,noheader"]).strip().splitlines():
        f = [x.strip() for x in line.split(",")]
        if len(f) < 13: continue
        gpus.append(dict(index=int(f[0]), name=f[1], memory_total=f[2], compute_cap=f[3], driver=f[4], bus_id=f[5],
                         pcie_gen_max=tbd(f[6]), pcie_gen_current=tbd(f[7]), pcie_width_max=tbd(f[8]), pcie_width_current=tbd(f[9]),
                         power_limit=tbd(f[10]), persistence_mode=tbd(f[11]), ecc=tbd(f[12])))
    hw["gpus"] = gpus
    smi = run(["nvidia-smi"])
    m = re.search(r"CUDA Version:\s*([\d.]+)", smi)
    hw["driver_cuda_version"] = m.group(1) if m else "TBD"
    hw["driver_version"] = gpus[0]["driver"] if gpus else "TBD"
    hw["topology_matrix"] = run(["nvidia-smi", "topo", "-m"])
    hw["nvlink_status"] = run(["nvidia-smi", "nvlink", "-s"])
    xml = run(["nvidia-smi", "-q", "-x"], timeout=120)
    if xml:
        open(os.path.join(out, "nvidia-smi-q.xml"), "w").write(xml)
    # PCIe link capability per GPU from lspci, when the bus is visible (usually not inside a container)
    lspci = {}
    for g in gpus:
        bdf = g["bus_id"].split(":", 1)[1].lower() if ":" in g["bus_id"] else ""
        txt = run(["lspci", "-vv", "-s", bdf]) if bdf else ""
        cap = re.search(r"LnkCap:.*?(Speed [^,]+), (Width x\d+)", txt)
        sta = re.search(r"LnkSta:.*?(Speed [^,]+), (Width x\d+)", txt)
        lspci[g["index"]] = {"LnkCap": f"{cap.group(1)}, {cap.group(2)}" if cap else "TBD",
                             "LnkSta": f"{sta.group(1)}, {sta.group(2)}" if sta else "TBD"}
    hw["lspci_links"] = lspci

    # --- host ---------------------------------------------------------------------
    lscpu = run(["lscpu"])
    def field(label):
        m = re.search(rf"^{label}:\s*(.+)$", lscpu, re.M); return m.group(1).strip() if m else "TBD"
    hw["cpu"] = {"model": field("Model name"), "cpus": field(r"CPU\(s\)"), "sockets": field(r"Socket\(s\)"),
                 "numa_nodes": field(r"NUMA node\(s\)"), "flags_avx512": "yes" if "avx512f" in lscpu else "no"}
    mem = run(["cat", "/proc/meminfo"])
    m = re.search(r"MemTotal:\s*(\d+) kB", mem)
    hw["ram_total_gib"] = round(int(m.group(1)) / 1048576, 1) if m else "TBD"
    try:
        cg = open("/sys/fs/cgroup/memory.max").read().strip()
        hw["cgroup_memory_max"] = cg
    except Exception:
        hw["cgroup_memory_max"] = "TBD"
    hw["disk_models_dir"] = run(["df", "-h", os.environ.get("MODEL_DIR", "/models")]).strip()
    hw["kernel"] = run(["uname", "-r"]).strip() or "TBD"
    osr = run(["cat", "/etc/os-release"])
    m = re.search(r'PRETTY_NAME="([^"]+)"', osr)
    hw["container_os"] = m.group(1) if m else "TBD"
    try:
        hw["build_info"] = json.load(open("/app/BUILD_INFO.json"))
    except Exception:
        hw["build_info"] = "TBD"
    json.dump(hw, open(os.path.join(out, "hardware.json"), "w"), indent=1)

    # --- markdown -----------------------------------------------------------------
    total_mib = sum(int(g["memory_total"].split()[0]) for g in gpus if g["memory_total"].split()[0].isdigit())
    names = sorted({g["name"] for g in gpus})
    md = [f"# {name} — {hw['cpu']['model']} + {len(gpus)} x {' / '.join(names) or 'TBD'} (rented, Vast.ai)", "",
          f"Read from inside the benchmark container on **{time.strftime('%Y-%m-%d')}** by `scripts/multigpu/bench/vast/collect-hardware.py`.",
          "`TBD` = not readable from a container without root (PCIe capability registers, motherboard, RAM modules).",
          "Everything else is the driver's own report. Vast.ai machine/instance ids are in `hardware.json`.", "",
          "## System", "", "| field | value | source |", "| --- | --- | --- |",
          f"| Host | Vast.ai rental, machine id {hw['vast'].get('VAST_MACHINE_ID', 'TBD')}, instance {hw['vast'].get('VAST_CONTAINERLABEL', hw['vast'].get('CONTAINER_ID', 'TBD'))} | environment |",
          f"| Container OS | {hw['container_os']} (host OS not visible) | `/etc/os-release` |",
          f"| Kernel | `{hw['kernel']}` | `uname -r` |",
          f"| CPU | {hw['cpu']['model']}, {hw['cpu']['cpus']} logical CPUs, {hw['cpu']['sockets']} socket(s), AVX-512 {hw['cpu']['flags_avx512']} | `lscpu` |",
          f"| NUMA | {hw['cpu']['numa_nodes']} node(s) | `lscpu` |",
          f"| RAM | {hw['ram_total_gib']} GiB visible (cgroup limit {hw['cgroup_memory_max']}); modules/speed TBD | `/proc/meminfo` |",
          f"| Motherboard | TBD (no DMI access in the container) | |",
          f"| NVIDIA driver | {hw['driver_version']} | `nvidia-smi` |",
          f"| Driver-reported CUDA | {hw['driver_cuda_version']} | `nvidia-smi` |",
          f"| Binaries | `BUILD_INFO.json` in the run directory (CUDA toolkit, SASS/PTX list, commits) | image |",
          "", "## GPUs", "",
          "| index | model | VRAM | compute cap. | PCI bus id | PCIe gen (max/current) | PCIe width (max/current) | power limit | ECC |",
          "| --- | --- | --- | --- | --- | --- | --- | --- | --- |"]
    for g in gpus:
        md.append(f"| {g['index']} | {g['name']} | {g['memory_total']} | {g['compute_cap']} | `{g['bus_id']}` | "
                  f"{g['pcie_gen_max']}/{g['pcie_gen_current']} | {g['pcie_width_max']}/{g['pcie_width_current']} | {g['power_limit']} | {g['ecc']} |")
    md += ["", f"**Aggregate VRAM: {total_mib} MiB ({total_mib / 1024:.0f} GiB).** PCIe gen/width \"current\" is what the driver",
           "reported at collection time (idle GPUs often sit at Gen1 in P8; the \"max\" column is the link capability).", ""]
    if any(v["LnkCap"] != "TBD" for v in lspci.values()):
        md += ["### PCIe link registers (`lspci -vv`)", "", "| GPU | LnkCap | LnkSta |", "| --- | --- | --- |"]
        md += [f"| {i} | {v['LnkCap']} | {v['LnkSta']} |" for i, v in lspci.items()]
        md.append("")
    if hw["topology_matrix"].strip():
        md += ["### Interconnect", "", "`nvidia-smi topo -m`:", "", "```", hw["topology_matrix"].rstrip(), "```", ""]
    if hw["nvlink_status"].strip():
        md += ["`nvidia-smi nvlink -s`:", "", "```", hw["nvlink_status"].rstrip(), "```", ""]
    open(os.path.join(out, "hardware.md"), "w").write("\n".join(md))
    print(f"hardware record: {len(gpus)} GPU(s), {total_mib} MiB total, driver {hw['driver_version']} (CUDA {hw['driver_cuda_version']}), CPU {hw['cpu']['model']}, RAM {hw['ram_total_gib']} GiB -> {out}/hardware.md")

if __name__ == "__main__":
    main()
