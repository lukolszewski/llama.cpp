# Patch index

Every downstream optimization should be one identifiable commit, so that the branch history reads as
`upstream llama.cpp + patch 1 + patch 2 + ...` and any single patch can be measured, generalized,
upstreamed, or deleted on its own.

Base: `df03399b8` (`opencl: add A8 Q4_0 mm binary kernel support (#28268)` — the upstream revision
that `master` and `multigpu` diverge from). Delta so far: **12 commits, 27 files, +2512/−294** before
the CI/documentation commits added on top.

| # | commit | date | area | what it does | switch | upstream ref |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | `b22bc5b68` | 2026-09-11 | qwen4exp / KV / CUDA FA | fixes CUDA decode depth-decay at long context; reworks the indexer-cache/KV path in `llama-memory-hybrid-idx` (559 lines) and `qwen4exp` attention | built in (no opt-out) | re: [ggml-org/llama.cpp#28734](https://github.com/ggml-org/llama.cpp/issues/28734) |
| 2 | `4d6ef5ad4` | 2026-09-12 | qwen4exp attention | compact-gather attention for decode so a **quantized** KV cache keeps the sparse speedup instead of falling back to dense f16 | built in | re: #28734; relies on the sparse-FA path merged upstream in [#27970](https://github.com/ggml-org/llama.cpp/pull/27970) |
| 3 | `b75e380e0` | 2026-09-20 | server slots | keeps busy slots on contiguous sequence ids by migrating a busy sequence into an idle slot's sequence, so several sessions decode inside one ubatch | `--seq-compact` / `--no-seq-compact` (default on), `LLAMA_ARG_SEQ_COMPACT` | — |
| 4 | `02e136bef` | 2026-09-21 | server scheduling | prefill admission policy: bound how many slots prefill inside one batch and how many "long" prompts run concurrently; exposes waiting metrics | `--prefill-max-partial` (1), `--prefill-long-threshold` (8192), `--prefill-max-long` (1) | — |
| 5 | `c8832a5f0` | 2026-09-21 | scheduler / CUDA | keeps ubatches overlapping across GPUs for the qwen4exp hybrid (pipeline parallelism), plus the small CUDA/alloc/argsort support changes it needs | `LLAMA_PIPELINE_PARALLEL` (`1` keeps PP on through tensor overrides, `0` forces off), `GGML_CUDA_GRAPHS_FORCE`, `GGML_CUDA_SEGMENTED_SORT` | — |
| 6 | `0f5aaf45d` | 2026-09-21 | ggml-backend | bounds pipeline depth so input copies trade against compute-buffer memory | `GGML_SCHED_N_COPIES` (default 4 = `GGML_SCHED_MAX_COPIES`, range 1..4) | — |
| 7 | `a4e856f1a` | 2026-10-03 | graph | builds the causal KQ mask on the device from cell positions instead of materializing it on the host and copying it | `LLAMA_KQ_MASK_DEVICE` (default on; `0` = host mask) | — |
| 8 | `9f5a3202e` | 2026-10-03 | qwen4exp QSA | builds the QSA block bias on the device | `LLAMA_QSA_BIAS_DEVICE` (default on; `0` = host) | — |
| 9 | `4660a295e` | 2026-10-03 | memory-hybrid-idx | splits a pure multi-sequence decode batch into per-sequence ubatches | `LLAMA_DECODE_PIPELINE` (default `0`) | — |
| 10 | `fb8897947` | 2026-10-03 | graph / KV | stream-agnostic decode graph so those per-sequence decode ubatches can run without per-stream graph constraints | `LLAMA_DECODE_PIPELINE` (same switch, this is the graph half) | — |
| 11 | `1567041ef` | 2026-10-03 | diagnostics | per-ubatch reuse/reserve/timing and per-split host-wait trace | `LLAMA_UBATCH_TRACE`, `GGML_SCHED_LOG_REALLOC` (both off unless set) | — |
| 12 | `1ca80a510` | 2026-10-03 | ggml-backend | stages scheduler inputs through rotating pinned buffers and copies them asynchronously on the compute stream | `GGML_SCHED_STAGE_INPUTS` (default on when the scheduler is parallel with `n_copies > 1`) | — |

## Runtime switches, with defaults read from the code

The whole patchset is selected at runtime, which means **one build carries all of it** — there are no
per-feature binaries and no custom CMake options. Defaults below were taken from the source, not
assumed.

| variable / flag | default | effect |
| --- | --- | --- |
| `LLAMA_DECODE_PIPELINE` | `0` (off) | off: upstream-like batch handling. `1`: pure multi-sequence decode batches are split into per-sequence ubatches and run through the stream-agnostic decode graph (patches 9, 10) |
| `LLAMA_PIPELINE_PARALLEL` | unset (upstream heuristic) | `1`: keep scheduler pipeline parallelism even when tensor overrides move input-stage tensors to CPU; `0`: force it off |
| `LLAMA_QSA_BIAS_DEVICE` | on | `0` restores the host-side QSA block bias (patch 8) |
| `LLAMA_KQ_MASK_DEVICE` | on | `0` restores the host-built causal KQ mask; 2-D M-RoPE image ubatches always keep the host mask (patch 7) |
| `GGML_SCHED_STAGE_INPUTS` | on (parallel scheduler) | `0` disables rotating pinned-buffer staging of user inputs (patch 12) |
| `GGML_SCHED_N_COPIES` | `GGML_SCHED_MAX_COPIES` = 4 | lowers pipeline depth and per-input compute-buffer memory (patch 6) |
| `GGML_CUDA_GRAPHS_FORCE` | off | forces CUDA graph capture/instantiate on otherwise-unsuitable calls (patch 5) |
| `GGML_CUDA_SEGMENTED_SORT` | off | `1` restores the previous argsort behaviour; default is the asynchronous segmented sort (patch 5) |
| `LLAMA_RESERVE_ON_DEMAND_DISABLE` | inherits the base default | `1` disables on-demand reserve (patch 5) |
| `LLAMA_GRAPH_REUSE_DISABLE` | upstream behaviour | existing llama.cpp switch, overridden by the patched context init when set (patch 5) |
| `LLAMA_UBATCH_TRACE` | off | set to any value to enable per-ubatch reuse/reserve/timing and host-wait traces (patch 11) |
| `GGML_SCHED_LOG_REALLOC` | off | set to any value to log every scheduler reallocation, each of which synchronizes all backends (patch 11) |
| `--prefill-max-partial N` | `1` | max slots prefilling within one batch; `1` = first slot takes the whole batch, others wait (patch 4) |
| `--prefill-long-threshold N` | `8192` | a prompt with more than N tokens left to prefill counts as "long" (patch 4) |
| `--prefill-max-long N` | `1` | max long prompts prefilling concurrently; the rest wait in arrival order (patch 4) |
| `--seq-compact` / `--no-seq-compact` | enabled | keep busy slots on contiguous sequence ids so they decode in one ubatch (patch 3) |
| `--cache-idle-slots` | enabled | save and clear idle slots when a new task starts (patch 3 area) |
| `LLAMA_ARG_PREFILL_MAX_PARTIAL` / `_LONG_THRESHOLD` / `_MAX_LONG`, `LLAMA_ARG_SEQ_COMPACT`, `LLAMA_ARG_CACHE_IDLE_SLOTS` | — | environment forms of the flags above |

## Comparing a patch against upstream

Because each patch has a switch (or is a self-contained commit), an A/B measurement does not need two
builds:

```sh
# patched default
LLAMA_DECODE_PIPELINE=1 llama-server ...

# closest upstream-equivalent behaviour for the decode path
LLAMA_DECODE_PIPELINE=0 LLAMA_QSA_BIAS_DEVICE=0 LLAMA_KQ_MASK_DEVICE=0 \
GGML_SCHED_STAGE_INPUTS=0 --no-seq-compact llama-server ...
```

Record which switches were flipped, the upstream commit and the multigpu commit with every number.
Env-only comparisons are cheaper than building twice, but they are **not** equivalent to upstream:
patches 1 and 2 have no opt-out, so the honest upstream comparison is always against a real upstream
build of the named commit.

## Obtaining individual patches

```sh
scripts/multigpu/export-patches.sh                 # git format-patch for the whole downstream range
scripts/multigpu/export-patches.sh -n 3            # only the last three patches
```

CI also publishes the range as a `patches-*.tar.gz` artifact on every build, so users can choose
between upstream, upstream + selected patches, or a complete `llama.cpp-multigpu` build. Explicit
`.patch` files are not committed: they would duplicate the history and go stale on the next rebase.

## Removal criteria

A patch is a candidate for deletion when upstream llama.cpp provides equivalent or better behaviour
for the target workload. The procedure per candidate:

1. identify the upstream commit that plausibly supersedes it;
2. re-sync `multigpu` onto a `master` that contains it;
3. benchmark the affected workloads (prefill and generation, 1 slot and 5 slots) at 5k/50k/150k/200k/250k;
4. if the patch no longer measurably helps, revert/drop it and note the drop here with the commit and
   the benchmark run that justified it;
5. if it still helps, keep it and record *why* the upstream version is insufficient, ideally in the
   linked upstream thread.

Dropping a patch is progress, not regression.

## Scope guard

This table is the project. A new commit here should answer: which workload on which hardware got
faster, and what number proves it? Unrelated llama.cpp features belong upstream. See
[../../README.md](../../README.md) non-goals.
