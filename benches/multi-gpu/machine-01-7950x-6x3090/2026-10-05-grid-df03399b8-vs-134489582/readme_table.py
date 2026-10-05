#!/usr/bin/env python3
# readme_table.py upstream.json multigpu.json -> markdown rows (ratio + delta), per-slot means in parentheses for 5 slots
import json, sys
U = json.load(open(sys.argv[1])); M = json.load(open(sys.argv[2]))
def find(d, n, s): return next((r for r in d["rows"] if r["slots"] == n and r["size_tokens"] == s), None)
def cell(r, key, n):
    if r is None: return "not run"
    if key == "pp":
        if "pp_error" in r: return "failed"
        return f"{r['pp_slot_mean']:.0f}" if n == 1 else f"{r['pp_agg']:.0f} ({r['pp_slot_mean']:.0f}/slot)"
    if "pp_error" in r or "tg_error" in r: return "failed"
    return f"{r['tg_slot_mean']:.1f}" if n == 1 else f"{r['tg_agg']:.1f} ({r['tg_slot_mean']:.1f}/slot)"
def imp(ru, rm, key):
    if ru is None or rm is None or "pp_error" in ru or "pp_error" in rm or (key=="tg" and ("tg_error" in ru or "tg_error" in rm)): return "n/a"
    k = ("pp_slot_mean" if key=="pp" else "tg_slot_mean") if ru["slots"] == 1 else ("pp_agg" if key=="pp" else "tg_agg")
    a = ru[k]; b = rm[k]
    return f"{b/a:.2f}x ({b-a:+.0f} t/s)" if key=="pp" else f"{b/a:.2f}x ({b-a:+.1f} t/s)"
print("| Workload | Context | Upstream llama.cpp | llama.cpp-multigpu | Improvement |\n| --- | --- | --- | --- | --- |")
for n, name in ((1, "1 slot"), (5, "5 slots - concurrent")):
    for s in (5000, 50000, 150000, 200000, 250000):
        ru, rm = find(U, n, s), find(M, n, s); k = f"{s//1000}k"
        print(f"| {name} - prefill | {k} | {cell(ru,'pp',n)} | {cell(rm,'pp',n)} | {imp(ru,rm,'pp')} |")
        print(f"| {name} - generate | {k} | {cell(ru,'tg',n)} | {cell(rm,'tg',n)} | {imp(ru,rm,'tg')} |")
