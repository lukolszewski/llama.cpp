# Benchmark scripts

These scripts implement the protocol in
[`docs/multigpu/benchmarks.md`](../../../docs/multigpu/benchmarks.md).

**Status: implemented, not executed.** No benchmark results exist for this fork yet, and nothing here
has produced a published number. Every table cell in the README and in `docs/multigpu/benchmarks.md`
remains `TBD` until a run is recorded under `benches/multi-gpu/<machine>/`.

| script | tier | needs GPU | what it does |
| --- | --- | --- | --- |
| `run-single-slot.sh` | measurement | yes | single active session: prefill and generation at 5k/50k/150k/200k/250k, via `llama-bench` |
| `run-5-slot.py` | measurement | yes | five concurrent slots against a running `llama-server -np 5`: all-prefill run, all-generate run, aggregate + per-slot t/s, TTFT, peak VRAM per device |
| `runtime-smoke.sh` | B | yes | proves the build loads the target model and serves requests on real hardware. Not a benchmark |
| `../../validate-artifact.sh` | A | no | offline packaging/integrity gate: does the archive say true things about itself |
| `../../env-snapshot.sh` | record | no | captures the machine/topology record that every result must be accompanied by |

## Usage

```sh
# 1. offline integrity gate on a downloaded or freshly built artifact (no GPU)
scripts/multigpu/validate-artifact.sh \
  --archive llama.cpp-multigpu-20261004+1ca80a5-bin-ubuntu-cuda-12.8-x64.tar.gz \
  --expect-arch sm_86,sm_89

# 2. Tier B smoke on the benchmark machine (needs idle GPUs)
scripts/multigpu/bench/runtime-smoke.sh \
  --model /data/models/Qwen3.8-Flash-Next-UD-Q4_K_XL-00001-of-00004.gguf \
  --bin ./build/bin/llama-server --slots 5 --ctx 32768

# 3. single-slot suite, upstream binary then multigpu binary, same machine and same model file
scripts/multigpu/bench/run-single-slot.sh --bin ./upstream/bin/llama-bench \
  --model /data/models/Qwen3.8-Flash-Next-UD-Q4_K_XL-00001-of-00004.gguf \
  --upstream-commit <sha> --multigpu-commit <sha> --out benches/multi-gpu/machine-01-7950x-6x3090/upstream-pp.csv

LLAMA_DECODE_PIPELINE=1 scripts/multigpu/bench/run-single-slot.sh \
  --bin ./multigpu/bin/llama-bench --model /data/models/...-00001-of-00004.gguf \
  --out benches/multi-gpu/machine-01-7950x-6x3090/multigpu-pp.csv

# 4. five-slot suite
llama-server -m ...-00001-of-00004.gguf -ngl 99 -sm layer -fa on -np 5 --ctx-size 200000 &
scripts/multigpu/bench/run-5-slot.py --server http://127.0.0.1:8080 --slots 5 \
  --size 50000 --phase pp --multigpu-commit <sha> --upstream-commit <sha> \
  --out benches/multi-gpu/machine-01-7950x-6x3090/5slot-50k-pp.json
```

## Rules these scripts encode

- each output file names the multigpu commit, the upstream commit, the host, the model, the
  configuration and the environment variables — because the patchset is switch-selected, an unlabeled
  run cannot be attributed to a patch;
- `cache_prompt` is disabled so a benchmark does not profit from a warm prompt cache;
- slot counts, context sizes and batch settings come from the command line and are echoed into the
  output header;
- **all-prefill and all-generate are separate runs.** Mixed prefill + generation is a known weak point
  (the two interfere) and is *not* measured by these scripts, so their numbers must never be presented
  as describing mixed or multi-tenant load;
- `runtime-smoke.sh` refuses to start when the GPUs already look busy, because a contended GPU proves
  nothing;
- the five-slot driver reports per-slot min/mean/max alongside aggregate throughput, since aggregate
  alone can hide a slot that starved.

## Not implemented on purpose

Mixed-workload suites (one generating + one prefilling, several generating + one prefilling, continuous
arrival mix) are described in `docs/multigpu/benchmarks.md#mixed-workload-behavior` as planned but
**not implemented**. No harness and no results exist for them, and none should be cited.

## Machine-dependence

These numbers only describe the machine they were taken on. On a single-GPU box, an NVLink-connected
box, or a server-class PCIe topology, the same switches can be neutral or harmful — several of these
patches exist specifically because consumer GPUs share constrained PCIe links.
