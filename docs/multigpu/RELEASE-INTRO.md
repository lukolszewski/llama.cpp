<!-- Prepended by scripts/multigpu/release-notes.sh to every tagged release body. Keep the numbers in sync with README §1. -->
## llama.cpp-multigpu

Upstream llama.cpp plus 47 performance patches for **Qwen3.8-Flash-Next** (`qwen4exp`) on consumer multi-GPU systems with
constrained PCIe (measured on 6 × RTX 3090). Same engine, same GGUF models, same `llama-server` API; the whole patchset is
selected at runtime by environment variables and a few server flags, so one build carries all of it. This is the
configuration running in production on the benchmark machine since 2026-10-05.

### Measured against upstream (same machine, same command line; upstream = the commit this patchset branches from)

| workload | 5k | 50k | 150k | 200k | 250k tokens |
| --- | --- | --- | --- | --- | --- |
| 1 slot prefill, upstream → multigpu (t/s) | 715 → 1249 | 568 → 2127 | 368 → 2152 | 315 → 2122 | 263 → 2111 |
| 1 slot decode (t/s) | 38.5 → 45.9 | 25.7 → 41.9 | 14.1 → 37.8 | 11.9 → 36.6 | 10.2 → 33.7 |
| 5 slots prefill, aggregate (t/s) | 630 → 2120 | 574 → 2301 | 363 → 2251 | 307 → 2180 | 265 → 2060 |
| 5 slots decode, per slot (t/s) | 18.2 → 42.3 | 8.1 → 38.3 | 3.6 → 32.4 | 2.8 → 29.0 | 2.3 → 27.3 |

Protocol, configuration and raw data: `docs/multigpu/benchmarks.md`, `benches/multi-gpu/machine-01-7950x-6x3090/`.

### What the patches do (every switch and commit: `docs/multigpu/patches.md`)

1. **Long-context decode and quantized KV (patches 1–2).** Fixes the CUDA decode slowdown of `qwen4exp` at depth and adds
   a compact-gather attention path so a `q8_0` KV cache keeps the sparse-attention speedup (upstream falls back to a dense
   path): 225k-context decode 22 → 44 t/s.
2. **Server scheduling (3–4).** Busy slots stay on contiguous sequence ids so several sessions decode in one ubatch; a
   prefill admission policy bounds how many prompts prefill at once (`--prefill-max-partial`, `--prefill-max-long`).
3. **Pipeline parallelism and device-built inputs (5–8).** Ubatches overlap across GPUs for this hybrid model
   (`LLAMA_PIPELINE_PARALLEL=1`, `GGML_CUDA_GRAPHS_FORCE=1`); the causal KQ mask and the QSA block bias are built on the
   device instead of being copied over PCIe every ubatch: prefill at 82k 1260 → 2360 t/s, flat to 250k.
4. **Per-sequence decode pipeline and decode groups (9–27).** `LLAMA_DECODE_PIPELINE=1` splits multi-user decode into
   per-sequence ubatches on a stream-agnostic graph; `LLAMA_SERVER_GROUPS=5` keeps several groups' batches in flight so
   users' tokens overlap across the GPUs instead of waiting for each other. 5 users at 58k: 17 → 34 t/s each.
5. **Prefill while others decode (28–36).** Prompts are prefilled in 256-token chunks beside the decoding slots without
   draining the pipeline: two users decoding during a 200k prefill see ~280 ms between tokens instead of 1.3 s.
6. **Asynchronous prompt cache (37–43).** Slot save/restore of multi-GiB KV states runs on worker threads with pinned
   staging and fences; context checkpoints no longer drain the pipeline; a 2.4 GiB restore takes ~1 s while the other
   users keep decoding (worst hitch 0.4 s).
7. **n-gram lookup speculation with the groups (44–47).** Prompt-lookup decoding (no draft model) made to work with the
   decode groups through recurrent-state snapshots in the memory, with a cap on drafting users and an acceptance gate.
   Off by default; `--spec-type ngram-map-k4v` + `LLAMA_SERVER_SPEC_MAX_USERS=2`: solo code rewrite 44 → 111 t/s.

Also fixed on the way: an output-slot leak that crashed the server after client disconnects under load, an output-buffer
reallocation that corrupted parked results, and the upstream n-gram map keeping stale state across prompts.

### Reference configuration (the numbers above were taken with it)

```
LLAMA_DECODE_PIPELINE=1 LLAMA_SERVER_GROUPS=5 LLAMA_PIPELINE_PARALLEL=1 GGML_CUDA_GRAPHS_FORCE=1 LLAMA_ATTN_ROT_DISABLE=1 \
llama-server -m Qwen3.8-Flash-Next-UD-Q4_K_XL-00001-of-00004.gguf -ngl 99 -fa on -np 5 -c 1310720 \
  --cache-type-k q8_0 --cache-type-v q8_0 -b 2048 -ub 512 -ot 'per_layer_token_embd\.weight=CPU' \
  --tensor-split 0.85,1,1,1,1,1 --prefill-max-partial 2
```

### Scope and caveats

Targeted at one model family on one class of hardware; other models and NVLink or single-GPU machines may not benefit and
can regress. Only sm_86 is runtime-validated by the maintainer; the other architectures in the archives are compiled, not
run. Mixed prefill + decode is better than upstream but still a documented limitation. Upstream llama.cpp remains the
general-purpose project; this fork exists to be archived once upstream catches up.
