#!/usr/bin/env python3
"""Five-slot concurrent benchmark driver for llama-server.

STATUS: implemented but NOT yet executed. No results exist for this fork; every published table cell is
TBD until a run is performed on a named machine with named commits. Do not quote output from a run you
have not made.

What it measures, per the protocol in docs/multigpu/benchmarks.md:

  --phase pp   all N slots prefill concurrently  (prompt processing)
  --phase tg   all N slots generate concurrently (decode, after a short shared warmup prompt)
  --phase both both phases in sequence

Reported: aggregate tokens/s, per-slot tokens/s (mean/min/max), time to first token per slot, total
prefill wall time, total generation wall time, per-request end-to-end latency, and peak VRAM sampled
from nvidia-smi in a side thread when available.

Deliberate limitation: this driver measures all-prefill and all-generate as *separate* runs. Mixed
prefill + generation is a known weak spot (they interfere with each other) and needs its own protocol;
the numbers produced here must not be read as describing a multi-tenant server.

Requires only the standard library plus a running llama-server (OpenAI-compatible /completions).

Example:
  llama-server -m ...-00001-of-00004.gguf -np 5 --ctx-size 200000 -ngl 99 -sm layer -fa on &
  scripts/multigpu/bench/run-5-slot.py --server http://127.0.0.1:8080 --slots 5 --size 50000 --phase pp
"""

import argparse
import json
import os
import random
import statistics
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request

STOP = threading.Event()


def log(msg):
    # noqa marker: this CLI reports measured throughput on stdout by design; flake8-no-print would
    # otherwise reject the script (upstream scripts/*.py use the same convention).
    print(msg, flush=True)  # noqa: NP100


def post(url, payload, timeout=None):
    """POST JSON and return (parsed body, elapsed seconds). Raises on HTTP errors."""
    data = json.dumps(payload).encode()
    req = urllib.request.Request(url + "/completion", data=data,
                                 headers={"Content-Type": "application/json"})
    start = time.perf_counter()
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        body = json.loads(resp.read().decode())
    return body, time.perf_counter() - start


def wait_ready(url, timeout=1200):
    """The 111 GB model takes a while to load; do not start the clock before it is up."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(url + "/health", timeout=10) as resp:
                if resp.status == 200:
                    return True
        except (urllib.error.URLError, urllib.error.HTTPError, OSError):
            time.sleep(2)
    return False


def synthetic_prompt(tokens, seed):
    """Deterministic filler prompt of roughly `tokens` tokens.

    Word-count based, so tokenization will not hit the requested count exactly; llama-server reports
    timings per token, and we rescale by the reported token counts rather than trusting our estimate.
    """
    rng = random.Random(seed)
    words = ["research", "context", "session", "token", "device", "window", "layer", "cache",
             "stream", "query", "value", "hidden", "expert", "router", "batch", "split"]
    out = []
    for i in range(tokens):
        out.append(rng.choice(words) + str(i % 997))
    return " ".join(out)


class VramSampler(threading.Thread):
    """Sample per-device memory with nvidia-smi. Silent no-op when the tool is unavailable."""

    def __init__(self, interval=1.0):
        super().__init__(daemon=True)
        self.interval = interval
        self.peak = {}
        self.samples = 0

    def run(self):
        while not STOP.is_set():
            try:
                out = subprocess.run(
                    ["nvidia-smi", "--query-gpu=index,memory.used", "--format=csv,noheader,nounits"],
                    capture_output=True, text=True, timeout=5).stdout.strip().splitlines()
            except Exception:
                return
            for line in out:
                parts = [p.strip() for p in line.split(",")]
                if len(parts) == 2:
                    try:
                        idx, used = parts[0], float(parts[1])
                    except ValueError:
                        continue
                    self.peak[idx] = max(self.peak.get(idx, 0.0), used)
            self.samples += 1
            time.sleep(self.interval)


def run_slot(url, slot, prompt, n_predict, temperature, seed):
    """One request in one server slot. Returns a metric dict for that slot."""
    payload = {
        "prompt": prompt,
        "n_predict": n_predict,
        "temperature": temperature,
        "seed": seed,
        "cache_prompt": False,   # a benchmark must not benefit from a warm prompt cache
        "parallel": slot,         # pin the request to a specific server slot id
    }
    t0 = time.perf_counter()
    body, elapsed = post(url, payload, timeout=None)
    t_done = time.perf_counter() - t0

    pp_ms = body.get("timings", {}).get("prompt_ms")
    pp_tokens = body.get("timings", {}).get("prompt_eval_len") or body.get("tokens_per_second", 0)
    tg_ms = body.get("timings", {}).get("predicted_ms")
    tg_tokens = body.get("timings", {}).get("predicted_n") or 0
    # llama.cpp also exposes these via timing_prompt_ms / predicted_ms at the top level in some builds
    pp_ms = pp_ms if pp_ms is not None else body.get("timing_prompt_ms")
    tg_ms = tg_ms if tg_ms is not None else body.get("predicted_ms")
    pp_tokens = pp_tokens or body.get("tokens_predicted", 0)

    res = {
        "slot": slot,
        "wall_s": round(t_done, 3),
        "prompt_tokens_reported": pp_tokens,
        "gen_tokens_reported": tg_tokens,
        "pp_ms": pp_ms,
        "tg_ms": tg_ms,
        "pp_tps": round(pp_tokens * 1000.0 / pp_ms, 2) if pp_ms else None,
        "tg_tps": round(tg_tokens * 1000.0 / tg_ms, 2) if tg_ms else None,
        "ttft_s": round((pp_ms or 0) / 1000.0, 3) if pp_ms else None,
    }
    if body.get("error"):
        res["error"] = body["error"]
    return res


def phase(args, name, prompt_tokens, n_predict):
    """Fire all slots concurrently, once per slot, and aggregate."""
    log(f"\n=== phase {name}: slots={args.slots} prompt_tokens~={prompt_tokens} n_predict={n_predict} ===")
    sampler = VramSampler()
    sampler.start()

    prompts = {s: synthetic_prompt(prompt_tokens, seed=args.seed + s) for s in range(args.slots)}
    results = [None] * args.slots
    errors = []

    def worker(s):
        try:
            results[s] = run_slot(args.server, s, prompts[s], n_predict, args.temperature,
                                  args.seed + s)
        except Exception as exc:  # keep the other slots' data even if one request fails
            errors.append({"slot": s, "error": repr(exc)})

    threads = [threading.Thread(target=worker, args=(s,)) for s in range(args.slots)]
    t0 = time.perf_counter()
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    wall = time.perf_counter() - t0
    STOP.set()
    sampler.join(timeout=3)
    STOP.clear()

    good = [r for r in results if r and "error" not in r]
    pp = [r["pp_tps"] for r in good if r["pp_tps"]]
    tg = [r["tg_tps"] for r in good if r["tg_tps"]]
    ttft = [r["ttft_s"] for r in good if r["ttft_s"] is not None]

    summary = {
        "phase": name,
        "slots": args.slots,
        "successful_requests": len(good),
        "failed_requests": errors,
        "wall_clock_s": round(wall, 3),
        "aggregate_pp_tps": round(sum(pp), 2) if pp else None,
        "mean_slot_pp_tps": round(statistics.mean(pp), 2) if pp else None,
        "min_slot_pp_tps": round(min(pp), 2) if pp else None,
        "max_slot_pp_tps": round(max(pp), 2) if pp else None,
        "aggregate_tg_tps": round(sum(tg), 2) if tg else None,
        "mean_slot_tg_tps": round(statistics.mean(tg), 2) if tg else None,
        "min_slot_tg_tps": round(min(tg), 2) if tg else None,
        "max_slot_tg_tps": round(max(tg), 2) if tg else None,
        "mean_ttft_s": round(statistics.mean(ttft), 3) if ttft else None,
        "max_ttft_s": round(max(ttft), 3) if ttft else None,
        "peak_vram_mib_per_device": {k: round(v, 1) for k, v in sampler.peak.items()},
        "per_slot": results,
    }
    log(json.dumps({k: v for k, v in summary.items() if k != "per_slot"}, indent=2))
    return summary


def host_record(args):
    """Provenance: without both commits and the machine, a number is meaningless."""
    rec = {
        "project": "llama.cpp-multigpu",
        "date": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "hostname": os.uname().nodename,
        "server": args.server,
        "slots": args.slots,
        "size_suite": args.size,
        "llama_server_binary": args.bin,
        "multigpu_commit": args.multigpu_commit,
        "upstream_commit": args.upstream_commit,
        "model": args.model,
        "kv_unified": args.notes_kv,
        "env": {k: v for k, v in os.environ.items() if k.startswith(("LLAMA_", "GGML_"))},
        "mixed_workload_note": "This driver runs all-prefill and all-generate separately. Prefill and "
                               "generation interfere when concurrent; those results are NOT a measure "
                               "of mixed-load or multi-tenant behaviour.",
    }
    return rec


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0],
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--server", default="http://127.0.0.1:8080", help="llama-server base URL")
    ap.add_argument("--slots", type=int, default=5, help="number of concurrent slots (server -np)")
    ap.add_argument("--size", type=int, default=50000, help="approx prompt tokens for this run")
    ap.add_argument("--gen-tokens", type=int, default=128, help="tokens to generate per slot")
    ap.add_argument("--phase", choices=["pp", "tg", "both"], default="both")
    ap.add_argument("--temperature", type=float, default=0.0)
    ap.add_argument("--seed", type=int, default=1234)
    ap.add_argument("--bin", default="TBD", help="path to the llama-server binary under test")
    ap.add_argument("--multigpu-commit", default="TBD")
    ap.add_argument("--upstream-commit", default="TBD")
    ap.add_argument("--model", default="TBD", help="model file(s), including quant")
    ap.add_argument("--notes-kv", default="TBD", help="KV cache type / unified KV setting")
    ap.add_argument("--out", default="", help="write JSON results here")
    ap.add_argument("--skip-health", action="store_true")
    args = ap.parse_args()

    if not args.skip_health and not wait_ready(args.server):
        log(f"server at {args.server} never became healthy (a 111 GB model can take a long time to "
            f"load; use --skip-health to bypass)")
        return 1

    report = host_record(args)
    report["results"] = []

    if args.phase in ("pp", "both"):
        # Prefill phase: long prompt, no generation, so decode time does not blur the measurement.
        report["results"].append(phase(args, "prefill", args.size, 1))
    if args.phase in ("tg", "both"):
        # Generation phase: short prompt first to populate contexts, then decode for n_predict tokens.
        # Each slot must hold its own context, so total resident context is slots * this size.
        warm = max(512, min(args.size, 4096))
        report["results"].append(phase(args, "generate", warm, args.gen_tokens))

    if args.out:
        with open(args.out, "w") as fh:
            json.dump(report, fh, indent=2)
        log(f"\nwrote {args.out}")
    print("\n" + json.dumps(report, indent=2)[:4000])  # noqa: NP100
    return 0


if __name__ == "__main__":
    sys.exit(main())
