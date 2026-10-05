#!/usr/bin/env python3
"""README benchmark grid: for each size, N slots prefill at once (n_predict 1, cache_prompt false), then N slots
generate 128 greedy tokens at that depth (cache_prompt true). usage: readme_grid.py URL LABEL OUT.json [slots=1,5] [sizes=...]"""
import json, sys, time, threading, urllib.request, subprocess
URL, LABEL, OUT = sys.argv[1], sys.argv[2], sys.argv[3]
SLOTS = [int(x) for x in (sys.argv[4] if len(sys.argv) > 4 else "1,5").split(",")]
SIZES = [int(x) for x in (sys.argv[5] if len(sys.argv) > 5 else "5000,50000,150000,200000,250000").split(",")]
GEN = 128
WORDS = ("system latency throughput kernel tensor gradient manifold entropy quantize scheduler pipeline embedding attention routing expert cache vector matrix decode prefill context window inference bandwidth compute memory buffer sparse dense token logits softmax").split()
def prompt(i, size, n_words):
    body = " ".join(WORDS[(i*7 + k*13) % len(WORDS)] for k in range(n_words))
    return f"[grid {LABEL} size {size} stream {i}] Deep context priming block. {body}. Now continue at length:"
def gpu():
    try: return subprocess.run(["nvidia-smi","--query-gpu=temperature.gpu,power.draw","--format=csv,noheader,nounits"],capture_output=True,text=True,timeout=10).stdout.strip().replace("\n",";")
    except Exception as e: return str(e)
def req(p, n_predict, cache):
    body = {"prompt": p, "n_predict": n_predict, "temperature": 0, "cache_prompt": cache, "ignore_eos": True}
    r = urllib.request.Request(URL + "/completion", data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
    t0 = time.time(); resp = json.loads(urllib.request.urlopen(r, timeout=7200).read()); return resp, time.time() - t0
def phase(prompts, n_predict, cache):
    res = [None]*len(prompts)
    def run(i):
        try: res[i] = req(prompts[i], n_predict, cache)
        except Exception as e: res[i] = ({"error": str(e)[:200]}, 0.0)
    th = [threading.Thread(target=run, args=(i,)) for i in range(len(prompts))]
    t0 = time.time(); [t.start() for t in th]; [t.join() for t in th]; return res, time.time() - t0
rows = []
def save(): json.dump({"label": LABEL, "url": URL, "gen_tokens": GEN, "rows": rows}, open(OUT, "w"), indent=1)
for n in SLOTS:
    for size in SIZES:
        n_words = int(size / 1.07)   # measured 1.07 tokens per word for this generator
        prompts = [prompt(10 + i, size, n_words) for i in range(n)]
        row = {"slots": n, "size_tokens": size, "gpu_before": gpu(), "t_start": time.strftime("%H:%M:%S")}
        pp, wall_pp = phase(prompts, 1, False)
        errs = [r[0]["error"] for r in pp if "error" in r[0]]
        if errs:
            row["pp_error"] = errs; rows.append(row); save(); print(f"{time.strftime('%H:%M:%S')} {LABEL} slots={n} size={size} PREFILL ERROR {errs[0]}", flush=True); continue
        pn = [r[0]["timings"]["prompt_n"] for r in pp]; pps = [r[0]["timings"]["prompt_per_second"] for r in pp]; ttft = [r[1] for r in pp]
        row.update(pp_agg=round(sum(pn)/wall_pp, 1), pp_slot_min=round(min(pps),1), pp_slot_mean=round(sum(pps)/n,1), pp_slot_max=round(max(pps),1), prompt_n=pn, ttft_min=round(min(ttft),1), ttft_max=round(max(ttft),1), pp_wall=round(wall_pp,1))
        tg, wall_tg = phase(prompts, GEN, True)
        errs = [r[0]["error"] for r in tg if "error" in r[0]]
        if errs:
            row["tg_error"] = errs
        else:
            tgs = [r[0]["timings"]["predicted_per_second"] for r in tg]; gen_n = [r[0]["timings"]["predicted_n"] for r in tg]; pn2 = [r[0]["timings"]["prompt_n"] for r in tg]
            row.update(tg_agg=round(sum(gen_n)/wall_tg, 2), tg_slot_min=round(min(tgs),2), tg_slot_mean=round(sum(tgs)/n,2), tg_slot_max=round(max(tgs),2), prompt_n_round2=pn2, tg_wall=round(wall_tg,1), texts=[r[0].get("content","")[:80] for r in tg])
        row["gpu_after"] = gpu(); rows.append(row); save()
        print(f"{time.strftime('%H:%M:%S')} {LABEL} slots={n} size={size} pn={pn[0]} pp_agg={row.get('pp_agg')} t/s (slot {row.get('pp_slot_mean')}) ttft={row.get('ttft_max')}s | tg_agg={row.get('tg_agg')} t/s (slot {row.get('tg_slot_mean')}, min {row.get('tg_slot_min')}) pn2={row.get('prompt_n_round2')} {row.get('tg_error','')} | text={row.get('texts',[''])[0][:50]!r}", flush=True)
print("GRID DONE", LABEL, flush=True)
