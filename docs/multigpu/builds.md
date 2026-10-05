# Builds, artifacts and releases

How the patched branch is built, packaged, labelled and validated. The point is reproducibility: from
any archive you can recover the exact source revision, the toolchain and the CMake configuration that
produced it.

## Branches and where builds come from

| branch | role | CI builds | CI releases |
| --- | --- | --- | --- |
| `master` | upstream llama.cpp mirror | not the downstream pipeline | **never** |
| `multigpu` | patched branch, repository default | yes | yes |

The downstream release workflow refuses to run on `master`, and upstream's own `release.yml` is gated
off on this fork so mirroring upstream cannot mint releases or burn Windows/macOS minutes.

Where GitHub does not allow expressions in `on: push: branches:`, the patched branch name appears
literally in the two workflow trigger blocks; grep for `MULTIGPU:PATCHED_BRANCH` to find every spot.
All *logic* is name-independent: jobs gate on `github.event.repository.default_branch` (optionally
overridden by the `MULTIGPU_PATCHED_BRANCH` repository variable), so renaming the branch mainly means
changing the default branch setting plus those trigger lines.

## Build configurations

Common flags (Linux CUDA, following upstream's proven `.devops/cuda.Dockerfile` recipe):

```
-DCMAKE_BUILD_TYPE=Release
-DGGML_NATIVE=OFF                # required: "native" means GPUs present at build time, and CI has none
-DGGML_CUDA=ON
-DGGML_BACKEND_DL=ON             # backends load from the archive directory ($ORIGIN rpath)
-DGGML_CPU_ALL_VARIANTS=ON       # portable CPU fallback alongside the CUDA backend
-DLLAMA_BUILD_SERVER=ON
-DLLAMA_BUILD_TOOLS=ON           # llama-cli, llama-bench, llama-batched-bench, ...
-DLLAMA_BUILD_EXAMPLES=OFF
-DLLAMA_BUILD_TESTS=OFF          # enabled only in the job that runs test-backend-ops
-DLLAMA_BUILD_UI=OFF
-DLLAMA_USE_PREBUILT_UI=OFF      # do not pull UI assets from an org-owned HF bucket during CI
-DCMAKE_CUDA_ARCHITECTURES="<list>"
-DCMAKE_EXE_LINKER_FLAGS=-Wl,--allow-shlib-undefined
-DCMAKE_INSTALL_RPATH='$ORIGIN' -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON
```

**A GPU is not required to build.** `nvcc` cross-compiles to SASS/PTX for whatever architecture list
is passed; the official `nvidia/cuda:*-devel` image supplies the toolkit, and CI supplies the
architecture list explicitly because `GGML_NATIVE=ON` (llama.cpp's default) resolves to `native` =
"GPUs present at build time", which is meaningless on a GPU-less runner. A GPU is required only to
*run* the result and to measure anything — see the validation tiers below.

### Architecture tiers

| configuration | arch list | when |
| --- | --- | --- |
| `cuda-12.8` merge build | `86-real;89-real` | every push to `multigpu` (RTX 3090 + RTX 4090) |
| `cuda-12.8` release build | `86-real;89-real;120a-real` | nightly + tagged (adds RTX 5090 / Blackwell) |
| `cuda-13.x` | `86-real;89-real;120a-real` | defined but commented out; enable when a CUDA 13 driver baseline is decided |

Each additional real architecture multiplies `nvcc` time and inflates `ggml-cuda.so` (expect roughly
1-2 GB), so merges keep a short list and releases carry the full one. CUDA 12.8 is the baseline because
`120a` requires ≥ 12.8 and 12.x keeps the runtime driver floor at the R525 branch family, whereas CUDA
13 builds want R580+.

### Platforms

| artifact | runner | CUDA | notes |
| --- | --- | --- | --- |
| `bin-ubuntu-cuda-<ver>-x64` | GitHub-hosted `ubuntu-24.04` + `nvidia/cuda` container | 12.8 | primary target for machine-01 |
| `cudart-ubuntu-cuda-<ver>-x64` | same | — | `libcudart`/`libcublas*` copied from the toolkit, for hosts without CUDA installed |
| `bin-ubuntu-x64` | GitHub-hosted `ubuntu-24.04` | off | CPU-only reference/fallback |
| `bin-win-cuda-<ver>-x64.zip` | GitHub-hosted `windows-2022` + `.github/actions/windows-setup-cuda` | 12.4 / 13.x | built on nightly/tagged/manual only: Windows runner minutes are metered at 10x |
| `cudart-llama-bin-win-cuda-<ver>-x64.zip` | same | — | `cudart64_*`, `cublas64_*`, `cublasLt64_*` |

Windows and CUDA 13 jobs are intentionally not part of every-merge CI.

## Artifact naming

```
llama.cpp-multigpu-<YYYYMMDD>+<multigpu-sha7>-bin-<os>-<backend>-<cuda>-<arch>.<ext>
```

Examples:

```
llama.cpp-multigpu-20261004+1ca80a5-bin-ubuntu-cuda-12.8-x64.tar.gz
llama.cpp-multigpu-20261004+1ca80a5-cudart-ubuntu-cuda-12.8-x64.tar.gz
llama.cpp-multigpu-20261004+1ca80a5-bin-win-cuda-12.4-x64.zip
llama.cpp-multigpu-20261004+1ca80a5-bin-ubuntu-x64.tar.gz
llama.cpp-multigpu-20261004+1ca80a5-patches.tar.gz
llama.cpp-multigpu-20261004+1ca80a5-BUILD_INFO.json
```

Every archive contains, at top level: `BUILD_INFO.json`, `BUILD_INFO.txt`, `LICENSE`, `AUTHORS`, and a
`README-MULTIGPU.md` pointer. Releases also carry `SHA256SUMS.txt`.

## Release scheme

Deliberately **not** an independent semantic version: this project does not define its own API, so a
`v0.3` style number would imply a stability contract that does not exist. Identity = date + commit +
upstream base.

| tag | meaning |
| --- | --- |
| `multigpu-latest` | rolling prerelease, refreshed nightly from the patched branch; assets replaced |
| `multigpu-YYYYMMDD` | permanent release, created by pushing that tag or via manual dispatch |
| `multigpu-YYYYMMDD.N` | same-day re-run |

Release titles are searchable and self-describing:

```
llama.cpp-multigpu — Qwen multi-GPU performance build — 2026-10-04
```

Release body always includes: multigpu commit, upstream base commit, CUDA/toolchain version, platform,
CMake configuration, downstream patch list, artifact table with the validation column, benchmark status
(`TBD` until numbers exist), the mixed-prefill/generation limitation, and the "if upstream now performs
comparably, use upstream" line.

To avoid release spam: merges produce CI artifacts (retained 14 days), never GitHub Releases. GitHub
Releases come from the nightly schedule or an explicit tag.

## Validation tiers

**Tier A — packaging/integrity gate. Offline, seconds, no GPU, applied to every artifact.**
Nothing in this tier claims the binary works on hardware; it proves the archive says true things:

- archive unpacks; `llama-server --version` and `--help` exit 0;
- `ldd` / dependency check resolves against the libraries shipped alongside or in the companion
  `cudart` archive;
- `cuobjdump --list-elf` confirms the CUDA fatbin contains the declared architectures, so metadata
  cannot overstate GPU support;
- `llama-server --help` advertises the downstream flags (`--prefill-max-partial`,
  `--prefill-long-threshold`, `--prefill-max-long`, `--seq-compact`, `--cache-idle-slots`) — a rebase
  that silently dropped a patch fails here;
- `BUILD_INFO.json` matches the git HEAD of the run;
- `LICENSE`/`AUTHORS` present; checksums recorded.

Implemented by `scripts/multigpu/validate-artifact.sh`, so the same checks can be run on a downloaded
archive locally.

**Tier B — runtime validation on real hardware. One configuration.**
Linux x86-64 / CUDA 12.8 / `sm_86`, because that is the machine we own. Runs only through the opt-in
self-hosted workflow (`multigpu-selfhosted.yml`), which loads Qwen3.8-Flash-Next `UD-Q4_K_XL` **from a
local path** (no 111 GB download in CI), starts a 5-slot server, generates a few tokens, records the
per-device memory split and runs one small `llama-bench` pass. Result is written as
`runtime_tested: true|false` into the build metadata and surfaced in the release asset table.

**Tier B status today: not yet executed.** The self-hosted runner is not registered, so every published
artifact currently carries `runtime_tested: TBD` and no configuration has our runtime claim. Tier A is
fully automated; Tier B requires you to attach `machine-01` as a runner (see the header comment of
`multigpu-selfhosted.yml` for the labels and the `MULTIGPU_MODEL_PATH` variable).

Everything else ships as an ordinary llama.cpp build: Tier A passed, Tier B not attempted, labelled
"built and packaging-checked; not runtime-validated by us". We do not publish claims for CUDA/driver
combinations we cannot run, we do not block releases waiting on validations that are impossible in our
CI, and we do not withhold artifacts from users whose hardware differs from ours. If the self-hosted
runner is offline, Tier B reads `TBD` and the release still publishes.

Reporting an untested configuration: use the
[performance issue template](../../.github/ISSUE_TEMPLATE/050-multigpu-perf.yml) with the archive name,
GPU model/count, driver and CUDA version — those reports are the only evidence we have about hardware
we do not own.

## Building manually

```sh
# any machine without a GPU, CUDA toolkit installed (or use the nvidia/cuda devel container)
cmake -S . -B build -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DGGML_NATIVE=OFF -DGGML_CUDA=ON \
  -DGGML_BACKEND_DL=ON -DCMAKE_CUDA_ARCHITECTURES="86-real" \
  -DLLAMA_BUILD_SERVER=ON -DLLAMA_BUILD_TOOLS=ON -DLLAMA_BUILD_EXAMPLES=OFF
cmake --build build -j$(nproc)

# provenance metadata for whatever you just built
scripts/multigpu/build-info.sh > build/bin/BUILD_INFO.json
```

Docker: upstream's `.devops/cuda.Dockerfile` builds this branch unchanged
(`CUDA_DOCKER_ARCH=86-real` recommended over the `default` list to keep the image small).
