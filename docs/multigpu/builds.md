# Builds, artifacts and releases

How the patched branch is built, packaged, labelled and validated. The point is reproducibility: from
any archive you can recover the exact source revision, the toolchain and the CMake configuration that
produced it.

## What CI builds, and when

| trigger | workflow | what comes out |
| --- | --- | --- |
| push to `multigpu` | `multigpu-build.yml` | one CUDA 12.9 build for `sm_86` only (RTX 3090, the benchmark/production hardware), upstream test suite (`ctest -L main`), Tier A gate, runtime image `ghcr.io/lukolszewski/llama.cpp-multigpu:server-cuda12.9-sm86` (+ `-<sha7>`); the tarball is kept 14 days as a CI artifact, never released |
| tag `multigpu-YYYYMMDD` | `multigpu-release.yml` | the two release flavours below as `.tar.gz` + `cudart` + `patches` + `SHA256SUMS.txt`, the GitHub Release (notes = `docs/multigpu/RELEASE-INTRO.md` + generated provenance and asset table), and both runtime images on ghcr |
| manual dispatch | both | same as above for an arbitrary ref / existing tag |

There are **no** pull-request builds, no nightly schedule, no rolling prerelease, and no Windows or
CPU-only artifacts. `master` (the upstream mirror) is never built or released from.

`runs-on` is read from the `MULTIGPU_RUNNER` repository variable (default: GitHub-hosted
`ubuntu-24.04`), so the builds can move to a self-hosted runner without editing the workflows.
Upstream's own workflows are disabled on this fork (`scripts/multigpu/disable-foreign-workflows.sh`;
rerun it after every upstream sync, GitHub re-registers workflows from the default branch).

## The two release flavours

| flavour | toolkit image | `CMAKE_CUDA_ARCHITECTURES` | native code (SASS) | PTX (JIT by the driver) | minimum driver |
| --- | --- | --- | --- | --- | --- |
| `cuda-12.9` | `nvidia/cuda:12.9.1-devel-ubuntu24.04` | `50-virtual;61-virtual;70-virtual;70-real;75-virtual;80-virtual;86-real;89-real;90-virtual;120a-real;121a-real` | `sm_70` (V100), `sm_86`, `sm_89`, `sm_120a`, `sm_121a` | `sm_50`, `sm_61`, `sm_70`, `sm_75`, `sm_80`, `sm_90` | R525+ (12.x minor-version compatibility) for the SASS targets; R570+ for Blackwell GPUs; R575+ (a driver that understands CUDA 12.9 PTX) for the PTX-only GPUs |
| `cuda-13.4` | `nvidia/cuda:13.4.1-devel-ubuntu24.04` | `80-virtual;86-real;89-real;90-virtual;120a-real;121a-real` | `sm_86`, `sm_89`, `sm_120a`, `sm_121a` | `sm_80`, `sm_90` | R580+ (CUDA 13); PTX-only GPUs need a driver as new as CUDA 13.4 |

Why these two:

- `cuda-12.9` is ggml's own default architecture list for a CUDA 12.9 toolkit plus `70-real`, so V100
  boxes get native code instead of PTX JIT. It spans every GPU from Maxwell to Blackwell on one
  toolkit, and 12.x keeps the driver floor at the R525 branch for the SASS targets.
- `cuda-13.4` exists for people who want the current toolkit. CUDA 13.0 removed offline compilation
  for Maxwell, Pascal and Volta, and Turing (`75`) is left out of this flavour on purpose: anyone with
  those GPUs takes `cuda-12.9`. Ampere and newer get the same SASS set as 12.9.
- A `-virtual` entry embeds PTX that the driver JIT-compiles at first load (slow first start, and the
  driver must be at least as new as the toolkit's PTX ISA). A `-real` entry embeds SASS that runs as-is
  on that exact architecture. The gate verifies both lists against the fatbin, so the table above is
  checked, not assumed.
- The sm_86 push image is only there to validate every merge quickly and to give machine-01 something
  to pull; it is not a release artifact.

Compile probe on machine-01 (2026-10-05, Ryzen 9 7950X, 32 threads, the exact CI recipe inside the
official devel images): both flavours compile cleanly (`exit 0`), `libggml-cuda.so` is 207 MB for
`cuda-12.9` (SASS for 5 architectures + 6 PTX) and 139 MB for `cuda-13.4`; `cuobjdump --list-elf`
showed the expected SASS sets. Wall time for `cuda-12.9` was 30 minutes while sharing the CPU with a
second compile; a cold `cuda-13.4` time was not measured (the probe's run hit a warm ccache).
Expect several hours per flavour on a GitHub-hosted 4-vCPU runner — the reason a self-hosted runner is
planned.

## Build recipe (both flavours, and the push build)

Following upstream's `.devops/cuda.Dockerfile`, inside the official `nvidia/cuda:*-devel-ubuntu24.04`
image (Ubuntu 24.04: gcc 13, cmake 3.28, ninja), with ccache:

```
-DCMAKE_BUILD_TYPE=Release
-DGGML_NATIVE=OFF                # required: "native" means GPUs present at build time, and CI has none
-DGGML_CUDA=ON
-DGGML_BACKEND_DL=ON             # backends load from the archive directory ($ORIGIN rpath)
-DGGML_CPU_ALL_VARIANTS=ON       # portable CPU fallback alongside the CUDA backend
-DLLAMA_BUILD_SERVER=ON
-DLLAMA_BUILD_TOOLS=ON           # llama-cli, llama-bench, llama-batched-bench, ...
-DLLAMA_BUILD_EXAMPLES=OFF
-DLLAMA_BUILD_TESTS=OFF          # ON in the push build, which runs ctest -L main (test-backend-ops skipped: no GPU)
-DLLAMA_BUILD_UI=OFF
-DLLAMA_USE_PREBUILT_UI=OFF      # no UI assets pulled from an org-owned bucket during CI
-DLLAMA_OPENSSL=ON               # HTTPS model downloads (libssl at runtime)
-DCMAKE_CUDA_ARCHITECTURES="<list from the table>"
-DCMAKE_EXE_LINKER_FLAGS=-Wl,--allow-shlib-undefined
-DCMAKE_INSTALL_RPATH='$ORIGIN' -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON
```

**A GPU is not required to build.** `nvcc` cross-compiles to SASS/PTX for whatever architecture list
is passed. A GPU is required only to *run* the result and to measure anything (see the validation
tiers). The web UI is not part of these archives; production on machine-01 serves an API, not a UI.

## Artifact naming and contents

```
llama.cpp-multigpu-<YYYYMMDD>-bin-ubuntu-cuda-12.9-x64.tar.gz      binaries + shared libraries (single top-level directory)
llama.cpp-multigpu-<YYYYMMDD>-cudart-ubuntu-cuda-12.9-x64.tar.gz   libcudart, libcublas, libcublasLt (+ libnvJitLink) of that toolkit
llama.cpp-multigpu-<YYYYMMDD>-bin-ubuntu-cuda-13.4-x64.tar.gz
llama.cpp-multigpu-<YYYYMMDD>-cudart-ubuntu-cuda-13.4-x64.tar.gz
llama.cpp-multigpu-<YYYYMMDD>-patches.tar.gz                        git format-patch series + PATCHES.md
BUILD_INFO-cuda-12.9.json, BUILD_INFO-cuda-13.4.json, SHA256SUMS.txt
```

The push build uses `llama.cpp-multigpu-<sha7>-bin-ubuntu-cuda-12.9-x64.tar.gz` (CI artifact only).

Every `bin` archive contains, in its top-level directory: `llama-server`, `llama-cli` and the other
tools, `libggml*.so`, `libllama*.so`, `libmtmd.so`, `BUILD_INFO.json`, `BUILD_INFO.txt`, `LICENSE`,
`AUTHORS`, `README-MULTIGPU.md`. The binaries find their libraries via `$ORIGIN`; unpack the `cudart`
archive into the same directory (or put it on `LD_LIBRARY_PATH`) on a host without a CUDA toolkit. The
NVIDIA driver (`libcuda.so.1`) always comes from the host.

`BUILD_INFO.json` fields: `multigpu_commit`, `upstream_base_commit`, `commits_ahead_of_upstream_base`,
`cuda_toolkit_version`, `cuda_nvcc`, `cuda_architectures` (the CMake list), `cuda_sass`, `cuda_ptx`,
`driver_floor`, `compiler`, `cmake`, `os`, `cmake_config`, `validation.tier_b_runtime`, `patches[]`.
Generated by `scripts/multigpu/build-info.sh`.

## Container images

`.devops/multigpu-cuda.Dockerfile` compiles nothing: CI unpacks the archive it just gated into `bin/`
and adds NVIDIA's `nvidia/cuda:<ver>-runtime-ubuntu24.04` base (cudart + cuBLAS), `libgomp1`,
`libssl3t64` and `curl` (health check). Layout matches upstream's `server` image: everything in `/app`,
entrypoint `/app/llama-server`, `LLAMA_ARG_HOST=0.0.0.0`, port 8080, `HEALTHCHECK` on `/health`.
CI runs `llama-server --version` inside the image and checks that `ldd` resolves everything except
`libcuda.so.1` before pushing.

| tag on `ghcr.io/lukolszewski/llama.cpp-multigpu` | from | moves? |
| --- | --- | --- |
| `server-cuda12.9-<YYYYMMDD>`, `server-cuda13.4-<YYYYMMDD>` | release archives | no |
| `server-cuda12.9`, `server-cuda13.4`, `latest` (= cuda12.9) | latest release | yes |
| `server-cuda12.9-sm86-<sha7>` | push build | no |
| `server-cuda12.9-sm86` | latest push to `multigpu` | yes |

The package was created by the first push with the workflow's `GITHUB_TOKEN` and is public (anonymous
`docker pull` works); check with `docker manifest inspect ghcr.io/lukolszewski/llama.cpp-multigpu:server-cuda12.9-sm86`
after a sync in case GitHub ever resets it.

## Release scheme

Deliberately **not** an independent semantic version: this project does not define its own API, so a
`v0.3` style number would imply a stability contract that does not exist. Identity = date + commit +
upstream base.

| tag | meaning |
| --- | --- |
| `multigpu-YYYYMMDD` | permanent release, created by pushing an annotated tag on the `multigpu` tip |
| `multigpu-YYYYMMDD.N` | same-day re-release (the workflow refuses to replace an existing release) |

```sh
git tag -a multigpu-20261005 -m "llama.cpp-multigpu 2026-10-05: <one line>"
git push origin multigpu-20261005          # -> multigpu-release.yml
```

Release title: `llama.cpp-multigpu 20261005 — Qwen3.8-Flash-Next multi-GPU performance build`. Body:
`docs/multigpu/RELEASE-INTRO.md` (what the patches do, the measured numbers, the reference
configuration, caveats — keep it in sync with README §1) followed by the generated provenance table, the
asset table with SASS/PTX/driver columns and validation state, and the patch list.

## Validation tiers

**Tier A — packaging/integrity gate. Offline, seconds, no GPU, applied to every artifact.**
Nothing in this tier claims the binary works on hardware; it proves the archive says true things:

- archive unpacks; `llama-server --version` and `--help` exit 0;
- `ldd` resolves against the libraries shipped alongside (the `cudart` bundle is checked for
  completeness the same way: only `libcuda.so.1` may be unresolved);
- `cuobjdump --list-elf` confirms every declared SASS architecture is in the fatbin and
  `cuobjdump --list-ptx` every declared PTX target (`--expect-arch`, `--expect-ptx`; the push build
  asserts `--expect-no-ptx`), so metadata cannot overstate GPU support;
- `llama-server --help` advertises the downstream flags (`--prefill-max-partial`,
  `--prefill-long-threshold`, `--prefill-max-long`, `--seq-compact`, `--cache-idle-slots`) — a rebase
  that silently dropped a patch fails here;
- `BUILD_INFO.json` matches the git commit of the run;
- `LICENSE`/`AUTHORS` present, no `.gguf` inside; checksums recorded.

Implemented by `scripts/multigpu/validate-artifact.sh`, so the same checks can be run on a downloaded
archive locally (inside a `nvidia/cuda:*-devel` container for the `cuobjdump` part).

**Tier B — runtime validation on real hardware. One configuration.**
Linux x86-64 / `sm_86` (6 × RTX 3090, machine-01), because that is the machine we own, and it is the
configuration that serves production and produced the README numbers. The opt-in self-hosted workflow
(`multigpu-selfhosted.yml`) formalizes it: load Qwen3.8-Flash-Next `UD-Q4_K_XL` from a local path,
start a 5-slot server, generate, record the per-device memory split, run one `llama-bench` pass. Until
that runner is registered, Tier B for a release means the maintainer pulling the `cuda-12.9` image on
machine-01 and running the smoke there.

Everything else (`sm_70`, `sm_89`, `sm_120a`/`sm_121a`, every PTX target, the whole `cuda-13.4`
flavour) ships as an ordinary llama.cpp build: Tier A passed, Tier B not attempted, labelled "built and
packaging-checked; not runtime-validated by us". We do not publish claims for CUDA/driver combinations
we cannot run, we do not block releases on validations that are impossible in our CI, and we do not
withhold artifacts from users whose hardware differs from ours.

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
scripts/multigpu/build-info.sh --cuda-arch 86-real --cuda-sass sm_86 > build/bin/BUILD_INFO.json
```

Docker from source: upstream's `.devops/cuda.Dockerfile` builds this branch unchanged
(`CUDA_DOCKER_ARCH=86-real` recommended over the `default` list to keep the image small); the
production images on machine-01 are built that way. `.devops/multigpu-cuda.Dockerfile` is the
packaging-only image described above.
