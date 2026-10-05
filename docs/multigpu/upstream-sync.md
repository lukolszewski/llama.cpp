# Syncing with upstream llama.cpp

The fork is only useful while it stays small and current. llama.cpp moves daily, so syncing is a
routine operation, and every sync is also an opportunity to delete patches that upstream has made
redundant.

## Branch model

```
upstream ggml-org/llama.cpp  ──fetch──▶  master (mirror)  ──rebase/merge──▶  multigpu (patched, default)
                                                                        ▲
                                                        CI builds and releases from here
```

- `master` tracks upstream as closely as practical and is **never** a release source.
- `multigpu` is `master` (or an older upstream commit) plus the identifiable patch series documented
  in [patches.md](patches.md).
- `upstream` remote: `https://github.com/ggml-org/llama.cpp.git`

```sh
git remote add upstream https://github.com/ggml-org/llama.cpp.git   # once
```

## Procedure

```sh
scripts/multigpu/sync-upstream.sh              # fetches, fast-forwards master, reports the delta
scripts/multigpu/sync-upstream.sh --rebase     # additionally rebases multigpu onto the new master
```

Manual equivalent, step by step:

1. **Update the mirror.** `git fetch upstream && git checkout master && git merge --ff-only upstream/master`.
   If a fast-forward is impossible, investigate before forcing: the mirror is only useful if it is
   literally upstream.
2. **Rebase or merge the patched branch.** Prefer `git rebase master multigpu` while the series is
   short — it keeps `upstream + patch 1..N` readable. Switch to merge commits if a rebase would
   rewrite commits that people have already built patches from; either way the patch boundaries must
   survive, because a squashed downstream blob cannot be measured, upstreamed or deleted per-patch.
3. **Resolve conflicts in patch order.** Expect the recurring hot spots to be the files the patchset
   already touches hardest: `src/llama-memory-hybrid-idx.*`, `src/models/qwen4exp.cpp`,
   `src/llama-graph.*`, `src/llama-context.*`, `ggml/src/ggml-backend.cpp`,
   `tools/server/server-context.cpp`.
4. **Build.** Locally or in CI; both the CUDA (Tier A) and CPU configurations. A sync that does not
   compile is not finished.
5. **Smoke test.** GPU-less: `scripts/multigpu/validate-artifact.sh` (checks the downstream flags still
   exist). With a GPU: `scripts/multigpu/bench/runtime-smoke.sh`.
6. **Benchmark the important workloads.** Minimum set: 1-slot prefill + generate at one mid and one
   large context, and 5-slot concurrent prefill + generate at one mid context. Full matrix only for
   releases. Record both commits.
7. **Delete what upstream made unnecessary.** For any patch whose upstream equivalent landed, follow
   [patches.md#removal-criteria](patches.md#removal-criteria) and note the drop. Deleting a patch is
   the normal direction of progress here.
8. **Release** only after 4-7: push a `multigpu-YYYYMMDD` tag, or let the nightly refresh
   `multigpu-latest`.

## Detecting that a patch is no longer needed

Signs to look for while reading upstream history:

- commits touching `ggml/src/ggml-backend.cpp` scheduler copies / `n_copies` / pinned staging;
- changes to `src/llama-graph.cpp` mask construction, or any generic "build mask on device" path;
- `llama-memory-hybrid-idx` or `qwen4exp` changes around sparse attention, indexer cache, or quantized
  KV handling;
- scheduler pipeline-parallelism conditions in `src/llama-context.cpp` (patch 5 loosened them);
- server slot scheduling, `--parallel` batch composition and prefill admission in
  `tools/server/server-context.cpp`.

Then measure, don't assume: a patch is redundant only when it no longer changes the numbers on
`machine-01`.

## Keeping the delta reviewable

- one logical optimization per commit, `perf(multigpu): ...` prefix, `Upstream-ref:` trailer;
- downstream-only files stay namespaced (`docs/multigpu/`, `scripts/multigpu/`, `benches/multi-gpu/`,
  `.github/workflows/multigpu-*.yml`) so rebases rarely conflict;
- the single functional edit to an existing upstream workflow is the `release.yml` publish gate;
- `git diff --stat master..multigpu` is the health check: if the file list starts growing without
  corresponding benchmark rows in `docs/multigpu/benchmarks.md`, scope is drifting.

## When sync is impossible

If a conflict cannot be resolved quickly, do not carry a broken patched branch forward: branch from the
last known-good commit, keep publishing that build (dated, with its upstream base commit visible), and
resolve the sync on a scratch branch. Users need honest, identifiable binaries more than they need the
newest upstream commit inside the fork.
