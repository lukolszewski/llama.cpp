#!/usr/bin/env python3
"""Render the README benchmark chart (SVG, no dependencies) from the raw grid JSON files.

    scripts/multigpu/bench/plot-grid.py benches/multi-gpu/<machine>/<run>/grid-upstream.json \
        benches/multi-gpu/<machine>/<run>/grid-multigpu.json -o benches/multi-gpu/<machine>/<run>/grid.svg

Every number drawn comes from the JSON produced by readme_grid.py (pp_slot_mean / pp_agg / tg_slot_mean):
nothing is typed in by hand, so re-running the grid and this script keeps README and chart in sync.
"""
import argparse, json

PANELS = [
    ("Prefill, 1 session",               1, "pp_slot_mean", "tokens/s"),
    ("Prefill, 5 concurrent sessions",   5, "pp_agg",       "tokens/s, aggregate"),
    ("Generation, 1 session",            1, "tg_slot_mean", "tokens/s"),
    ("Generation, 5 concurrent sessions",5, "tg_agg",       "tokens/s, aggregate over 5 sessions"),
]
W, H = 1060, 680
PW, PH = 400, 215          # panel plot area
X0, Y0 = 70, 100           # first panel origin
GX, GY = 110, 90           # gaps
COL_UP, COL_MG = "#8a8a8a", "#d35400"

def load(path):
    d = json.load(open(path))
    return {(r["slots"], r["size_tokens"]): r for r in d["rows"]}, d

def nice_max(v):
    for step in (10, 20, 50, 100, 200, 500, 1000):
        top = ((int(v) // step) + 1) * step
        if top / step <= 6:
            return top, step
    return int(v) + 1, max(1, int(v) // 5)

def fmt(v):
    return f"{v:.0f}" if v >= 100 else f"{v:.1f}"

def panel(out, ox, oy, title, up, mg, sizes, ylabel):
    ymax, step = nice_max(max(up + mg))
    def X(s): return ox + (s - sizes[0]) / (sizes[-1] - sizes[0]) * PW
    def Y(v): return oy + PH - v / ymax * PH
    out.append(f'<text x="{ox}" y="{oy-28}" class="t">{title}</text>')
    out.append(f'<text x="{ox}" y="{oy-11}" class="s">{ylabel}</text>')
    for v in range(0, ymax + 1, step):
        out.append(f'<line x1="{ox}" y1="{Y(v):.1f}" x2="{ox+PW}" y2="{Y(v):.1f}" class="g"/>')
        out.append(f'<text x="{ox-8}" y="{Y(v)+4:.1f}" class="s" text-anchor="end">{v}</text>')
    for s in sizes:
        out.append(f'<text x="{X(s):.1f}" y="{oy+PH+18}" class="s" text-anchor="middle">{s//1000}k</text>')
    out.append(f'<text x="{ox+PW/2:.1f}" y="{oy+PH+36}" class="s" text-anchor="middle">context length (tokens)</text>')
    for vals, col, dash, name in ((up, COL_UP, ' stroke-dasharray="6 4"', "upstream llama.cpp"), (mg, COL_MG, "", "llama.cpp-multigpu")):
        pts = " ".join(f"{X(s):.1f},{Y(v):.1f}" for s, v in zip(sizes, vals))
        out.append(f'<polyline points="{pts}" fill="none" stroke="{col}" stroke-width="2.5"{dash}/>')
        for s, v in zip(sizes, vals):
            out.append(f'<circle cx="{X(s):.1f}" cy="{Y(v):.1f}" r="3.5" fill="{col}"/>')
        # value labels at both ends
        for s, v, anchor, dx in ((sizes[0], vals[0], "start", 10), (sizes[-1], vals[-1], "end", -6)):
            dy = -8 if col == COL_MG else 18
            out.append(f'<text x="{X(s)+dx:.1f}" y="{Y(v)+dy:.1f}" class="v" fill="{col}" text-anchor="{anchor}">{fmt(v)}</text>')
    ratio = mg[-1] / up[-1]
    out.append(f'<text x="{ox+PW}" y="{oy-11}" class="r" fill="{COL_MG}" text-anchor="end">{ratio:.1f}× at {sizes[-1]//1000}k</text>')

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("upstream"); ap.add_argument("multigpu"); ap.add_argument("-o", "--out", required=True)
    ap.add_argument("--note", default="Qwen3.8-Flash-Next UD-Q4_K_XL · 6 × RTX 3090 (machine-01) · 5 slots × 262k ctx · q8_0 KV · 128 greedy tokens · upstream df03399b8 vs multigpu 134489582 · 2026-10-05")
    a = ap.parse_args()
    up, dup = load(a.upstream); mg, dmg = load(a.multigpu)
    sizes = sorted({k[1] for k in mg})
    out = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" font-family="-apple-system, Segoe UI, Helvetica, Arial, sans-serif">',
           '<style>.t{font-size:15px;font-weight:600;fill:#222}.s{font-size:11px;fill:#555}.g{stroke:#e3e3e3;stroke-width:1}.v{font-size:11px;font-weight:600}.r{font-size:13px;font-weight:700}.h{font-size:12px;fill:#333}</style>',
           f'<rect width="{W}" height="{H}" fill="#ffffff"/>']
    # legend
    out.append(f'<line x1="{X0}" y1="24" x2="{X0+28}" y2="24" stroke="{COL_UP}" stroke-width="2.5" stroke-dasharray="6 4"/><text x="{X0+34}" y="28" class="h">upstream llama.cpp</text>')
    out.append(f'<line x1="{X0+200}" y1="24" x2="{X0+228}" y2="24" stroke="{COL_MG}" stroke-width="2.5"/><text x="{X0+234}" y="28" class="h">llama.cpp-multigpu</text>')
    out.append(f'<text x="{X0}" y="50" class="s">{a.note}</text>')
    for i, (title, slots, key, ylabel) in enumerate(PANELS):
        ox = X0 + (i % 2) * (PW + GX); oy = Y0 + (i // 2) * (PH + GY)
        panel(out, ox, oy, title, [up[(slots, s)][key] for s in sizes], [mg[(slots, s)][key] for s in sizes], sizes, ylabel)
    out.append("</svg>")
    open(a.out, "w").write("\n".join(out) + "\n")
    print(f"wrote {a.out}")

if __name__ == "__main__":
    main()
