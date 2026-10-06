# Benchmarking on rented machines (Vast.ai)

The README grid (1 and 5 sessions × 5k/50k/150k/200k/250k tokens, prefill and generation) was measured on
`machine-01`, the maintainer's 6 × RTX 3090. This directory makes the same measurement reproducible on
rented multi-GPU machines — 6 × RTX 4090, 6–8 × RTX 5090, a few RTX 6000 / PRO 6000, 8 × Tesla V100 32 GB —
with **one image** and one command, and lands the results in this repository as a reviewable pull request.

| piece | what it is |
| --- | --- |
| `.devops/multigpu-bench.Dockerfile` | the gated **cuda-12.9 server image** (V100 → RTX 5090: SASS sm_70/86/89/120a/121a, PTX for the rest) plus aria2, python3, the grid protocol scripts and the entrypoint below. Pushed by CI as `ghcr.io/lukolszewski/llama.cpp-multigpu:bench-cuda12.9-<version>` / `:bench-cuda12.9` (releases) and `:bench-cuda12.9-<sha7>` / `:bench-cuda12.9-dev` (branches, `multigpu-bench-image.yml`). Public, no registry login needed on the rented box |
| `entrypoint.sh` | modes `bench` (default), `serve`, `download`, `hardware`, `dry-run`, `shell`. `bench`: pre-flight (GPU count, VRAM, driver vs PTX), hardware record, model download, VRAM-proportional tensor split, llama-server with the machine-01 flags, grid on the fork's binary and optionally on the upstream baseline, `DONE`/`FAILED` markers in `/results` |
| `download-model.sh` | HF download with 16 connections per file, resume, sha256 against the LFS oid; `HF_TOKEN` optional (the model repo is public), `HF_FILES` for explicit files |
| `collect-hardware.py` | `hardware.json` + `hardware.md` in the `benches/multi-gpu/<machine>/hardware.md` format; `TBD` for anything a container cannot read |
| `../readme_grid.py`, `../readme_table.py`, `../plot-grid.py` | the protocol, byte-identical to the copies committed next to the machine-01 raw data (the table script additionally accepts `-` for a missing upstream side) |
| `vast-bench.sh` | the workstation side: search offers, budget check, create the instance, wait, stream the log, fetch `/results` over SSH, destroy, generate the tables, branch + PR |
| `test-local.sh` | the gates to run on the workstation before spending money (no production GPU involved) |
| `.github/workflows/multigpu-baseline.yml` | builds an **unmodified upstream** commit with the cuda-12.9 release recipe and attaches it to a `baseline-<sha7>` prerelease; the bench image downloads it for the upstream side (upstream ships no Linux CUDA tarball or `server-cuda-b<N>` image for these builds) |

## Rules

- **No GitHub credential on the rented machine.** A Vast host is somebody else's computer. The box only
  pulls public things (image, model, baseline tarball); results travel back over SSH; the workstation
  commits and opens the PR with the operator's own credentials. `vast-bench.sh` refuses to forward any
  variable that looks like a GitHub token.
- The only secret that may be passed is `HF_TOKEN`, and only via `--hf-token-env NAME` (needed for gated
  repos; the default repo is public).
- Results land through a PR on `bench/<machine>-<date>`, never a direct push: every published number
  carries both commits, the machine record and the configuration, and someone reads them first.
- Spend is capped: `--max-usd` (worst case = `$/h × --max-hours` + disk + ~115 GB of ingress) is checked
  against the account credit; `--max-hours` destroys the instance on timeout; the instance is destroyed on
  every exit path (success, failure, Ctrl-C) unless `--keep`. `vast-bench.sh destroy --cleanup` kills
  every `mgbench-*` instance the account still has.
- Numbers are never typed. `land` regenerates `grid-table.md`, the `docs/multigpu/benchmarks.md` section
  and the README row from the JSON.

## Usage

```sh
# 0. gates on the workstation (builds the image locally from the latest release server image)
scripts/multigpu/bench/vast/test-local.sh                 # dryrun + download + bench on GPU_DEVICE (default 6)

# 1. what is rentable right now (free)
scripts/multigpu/bench/vast/vast-bench.sh search --gpu RTX_4090 --num-gpus 6
scripts/multigpu/bench/vast/vast-bench.sh search --gpu Tesla_V100 --num-gpus 8 --min-inet 500

# 2. patched side only (≈ 1 h on 6 × 4090: 15–50 min download + 35 min grid), results -> branch + PR
scripts/multigpu/bench/vast/vast-bench.sh run --gpu RTX_4090 --num-gpus 6 --max-dph 3.5 --max-usd 8 --max-hours 2

# 3. both sides (upstream grid is 3–4 h on 3090-class hardware: the 5-slot deep rows decode at 2–4 t/s)
scripts/multigpu/bench/vast/vast-bench.sh run --gpu RTX_4090 --num-gpus 6 --upstream --max-usd 20 --max-hours 6
#    cheaper: upstream on a subset
scripts/multigpu/bench/vast/vast-bench.sh run --gpu RTX_4090 --num-gpus 6 --upstream --upstream-sizes 5000,50000,250000 --max-usd 12 --max-hours 4

# 4. land results fetched earlier (or after --no-land), generate tables/docs, open the PR
scripts/multigpu/bench/vast/vast-bench.sh land --results ~/.cache/mgbench/results-<instance> --machine-name machine-02-6x4090

# housekeeping
scripts/multigpu/bench/vast/vast-bench.sh status [--instance ID]
scripts/multigpu/bench/vast/vast-bench.sh destroy --cleanup
```

Rehearsal before a big box (what the first run of this tooling did; < $0.30):

```sh
scripts/multigpu/bench/vast/vast-bench.sh run --gpu RTX_3090 --num-gpus 1 --min-vram 20 --min-cpu-ram 16 --min-disk 40 \
  --max-usd 1 --max-hours 1 --disk 40 --sizes 2000,5000 --slots 1,2 \
  --env HF_REPO=unsloth/Qwen3-0.6B-GGUF --env HF_FILES=Qwen3-0.6B-Q8_0.gguf --env MODEL_FILE=Qwen3-0.6B-Q8_0.gguf \
  --env PARALLEL=2 --env CTX=16384 --env MIN_GPUS=1 --env OT= --machine-name rehearsal-1x3090 --no-pr
```

### Options of `run`

| option | default | meaning |
| --- | --- | --- |
| `--gpu NAME --num-gpus N` | required | Vast spelling: `RTX_4090`, `RTX_5090`, `Tesla_V100`, `RTX_2080_Ti`, `RTX_6000Ada`, `RTX_PRO_6000_S` |
| `--max-usd`, `--max-hours`, `--max-dph` | 10, 5, none | budget cap, wall cap (instance destroyed), price filter |
| `--offer ID` | cheapest match | pin an offer from `search` |
| `--machine-id ID` | | only offers on that physical machine (`machine_id` from `hardware.json`/the run log): rerun both sides on the box an earlier run used |
| `--image` | `…:bench-cuda12.9` | the bench image (use `…:bench-cuda12.9-<version>` to pin) |
| `--upstream` / `--no-upstream` | off | also run the upstream baseline on the same instance after the patched grid |
| `--sizes`, `--slots` | README grid | token sizes / session counts; `--upstream-sizes`, `--upstream-slots` for the baseline side |
| `--machine-name` | `machine-NN-<n>x<gpu>` | directory under `benches/multi-gpu/` |
| `--disk` | 180 GB | instance disk (model 104 GB + image) |
| `--min-inet`, `--min-cpu-ram`, `--min-disk`, `--min-vram`, `--min-reliability` | 800 Mb/s, 48 GB, 160 GB, 140 GB, 0.95 | offer filters (VRAM filter is applied client-side on `gpu_total_ram`) |
| `--query 'expr'` | | extra Vast filter, e.g. `--query 'geolocation in [US,CA]'` |
| `--ingress-gb` | 115 | download volume used in the cost estimate (some hosts charge $0.01–0.02/GB; the model is 104 GB) |
| `--env K=V` | | extra container variables (see the entrypoint's knobs) |
| `--hf-token-env NAME` | none | forward `$NAME` as `HF_TOKEN` |
| `--boot-timeout`, `--ssh-timeout`, `--poll` | 1800 s, 600 s, 60 s | image pull + boot can take 20+ min on a slow host (seen: 15 min for 4 GB); the instance is destroyed on expiry |
| `--no-land`, `--no-pr`, `--keep`, `--dry-run` | | stop after fetch / land locally only / do not destroy / search only |

Exit codes: 2 no offer or over budget, 3 instance never ran, 4 remote `FAILED`, 5 SSH unreachable, 6
`--max-hours` timeout. Results (also on failure, for the logs) are in `~/.cache/mgbench/results-<instance>/`.

## What comes back

`/results` of the instance, copied to `benches/multi-gpu/<machine>/<date>-grid-<upstream7>-vs-<multigpu7>/`
(or `…-grid-<multigpu7>-only/` when the upstream side was not run):

`bench.log` (every step timestamped), `hardware.md` / `hardware.json` / `nvidia-smi-q.xml`, `config.json`
(every knob as used), `COMMITS.txt`, `BUILD_INFO.json` (from the image), `grid-multigpu.json`,
`grid-multigpu-server.log`, optionally `grid-upstream.json` + `grid-upstream-server.log` + `grid.svg`,
`grid-table.md`, `download-seconds`, `DONE` or `FAILED`.

## Driver and architecture caveats

- The image is NVIDIA's `cuda:12.9.1-runtime` base with `NVIDIA_DISABLE_REQUIRE=1` and **without** the
  `cuda-compat-12-9` package: with it, hosts whose driver is older than the compat `libcuda` (575) made ggml
  fall back to the CPU on GeForce ("forward compatibility was attempted on non supported HW"; 8 × 4090, driver
  570, 2026-10-06, ~$3 of CPU benchmarking). Without it the host driver's `libcuda` is used and any R525+ driver
  works for the SASS targets. The pre-flight now runs `llama-server --list-devices` and refuses to download the
  model when fewer CUDA devices than selected GPUs show up; after load it requires ≥ 10 GiB of VRAM in use
  (`MIN_LOADED_MIB`); the orchestrator aborts on a first grid row below `--min-pp 300` / `--min-tg 5` t/s and
  then **keeps the instance for repair in place** (`--no-repair` to destroy instead).
- GPUs that only have **PTX** in the build (Turing `sm_75`: RTX 2080 Ti, T4) need a driver that knows CUDA
  12.9 PTX (R575+). The entrypoint checks the driver's CUDA version against `BUILD_INFO.json` and aborts
  with a clear message; `vast-bench.sh` adds `cuda_vers>=12.9` to the search for Turing names.
- Blackwell (`sm_120`) needs R570+; Vast's current fleet is on R570–R610 (checked 2026-10-06).
- V100: flash attention uses llama.cpp's non-tensor-core kernels for sm_70; q8_0 KV + `-fa on` is the
  configuration tried first; the server log records what ran.
- 4 × RTX 2080 Ti 22 GB (88 GB) is below the 140 GB this model needs; only an 8-card box qualifies.

## Upstream baseline

Upstream publishes neither a Linux CUDA tarball nor a `ghcr.io/ggml-org/llama.cpp:server-cuda-b<N>` image
for build b10902 (= `df03399b8`, the fork's base) or its neighbours (checked for b10850–b10902 on
2026-10-06). So the comparison binary is built by this repository: `multigpu-baseline.yml` compiles the
upstream commit with exactly the cuda-12.9 release recipe (same toolchain image, same CMake flags, same
architecture list, no downstream patches, gate-checked with `validate-artifact.sh --upstream-build`) and
attaches it to the prerelease `baseline-<sha7>`. The bench image's `upstream` side downloads that tarball
(190 MB) into `/opt/upstream` and runs it with the same command line minus the fork-only
`--prefill-max-partial`. Trigger a baseline for another commit with `git tag baseline-<sha7> && git push
origin baseline-<sha7>` (any commit that contains the workflow) or `gh workflow run multigpu-baseline.yml -f
upstream_sha=<sha>`.

## Vast.ai specifics learned

Recorded from the rehearsal; see the git history of this file for changes.

- `vastai create instance <offer> --image IMG --disk GB --ssh --direct --label L --onstart-cmd CMD --raw`:
  in `--ssh` mode Vast runs its own init (sshd) and the image `ENTRYPOINT` is **not** executed; the work is
  started by `--onstart-cmd`, which `vast-bench.sh` builds as `env K=V … nohup entrypoint.sh bench &` so the
  configuration does not depend on how `--env` is propagated.
- `vastai ssh-url ID` gives `ssh://root@HOST:PORT` (direct port when `--direct` worked); the account's SSH
  key (`~/.ssh/vastai_ed25519` here, registered in the console) is injected into the container.
- Results are pulled with `ssh … 'tar -C /results -czf - .' | tar -xzf -` (no rsync in the image, no
  dependency on `vastai copy` semantics).
- `vastai show user --raw` → `credit` is the balance; the CLI table's "Balance" column shows 0 for this
  account and is not the credit.
- `vastai destroy instance ID` prompts for confirmation even without a TTY and prints `Aborted.`; always
  pass `-y`.
- When the offer disappears between `search` and `create`, Vast silently creates a **stopped** instance
  (`intended_status: stopped`, `actual_status: loading` forever). `vast-bench.sh` passes `--cancel-unavail`
  and, if it still happens, tries `vastai start instance` once before giving up.
- Vast's ssh launcher writes `/root/.ssh/authorized_keys` with modes a stock `sshd` refuses
  ("Authentication refused: bad ownership or modes", visible in `vastai logs ID`); the bench image sets
  `StrictModes no` (key-only root login stays). The ssh client must use `IdentitiesOnly=yes`: an agent
  with several keys trips `MaxAuthTries` before the right key is offered.
- `vastai execute` only works on **stopped** instances and only for `ls`/`rm`/`du`; `vastai logs ID`
  (container stdout + sshd log) is the diagnostic channel while it runs.
- Image pull time on the host varies from 3 to 15+ minutes for this 2.5 GB image; the boot timeout is
  30 min by default.
