#!/usr/bin/env bash
# Compose the GitHub Release body for a tagged llama.cpp-multigpu release.
#
# Body = docs/multigpu/RELEASE-INTRO.md (hand-written: what the patches do, the measured numbers, the
# reference configuration, caveats) + generated provenance (commits, toolchains) + the asset table with
# per-flavour GPU coverage and driver floors + the downstream patch list.
#
# Usage: scripts/multigpu/release-notes.sh --intro docs/multigpu/RELEASE-INTRO.md \
#         --meta DIR            (one BUILD_INFO-<flavour>.json per build flavour, from build-info.sh) \
#         --assets-manifest FILE (name<TAB>flavour<TAB>cuda<TAB>sass<TAB>ptx<TAB>driver<TAB>validation) \
#         --tag multigpu-YYYYMMDD [--repo owner/name]

set -euo pipefail

INTRO=""
META=""
MANIFEST=""
TAG=""
REPO="${GITHUB_REPOSITORY:-lukolszewski/llama.cpp-multigpu}"

while [ $# -gt 0 ]; do
    case "$1" in
        --intro)           INTRO="$2"; shift 2 ;;
        --meta)            META="$2"; shift 2 ;;
        --assets-manifest) MANIFEST="$2"; shift 2 ;;
        --tag)             TAG="$2"; shift 2 ;;
        --repo)            REPO="$2"; shift 2 ;;
        -h|--help)         grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "release-notes: unknown argument: $1" >&2; exit 1 ;;
    esac
done

[ -n "$META" ] || { echo "release-notes: --meta is required" >&2; exit 1; }
JSON="$(find "$META" -maxdepth 1 -name '*BUILD_INFO*.json' | sort | head -1)"
[ -n "$JSON" ] || { echo "release-notes: no BUILD_INFO json under $META" >&2; exit 1; }

get() { python3 -c "import json,sys;d=json.load(open(sys.argv[1]));print(d.get(sys.argv[2], 'TBD'))" "$1" "$2"; }

MG_COMMIT="$(get "$JSON" multigpu_commit)"
UP_COMMIT="$(get "$JSON" upstream_base_commit)"
UP_DATE="$(get "$JSON" upstream_base_commit_date)"
PATCH_COUNT="$(python3 -c "import json,sys;print(len(json.load(open(sys.argv[1])).get('patches',[])))" "$JSON")"
BASE_URL="https://github.com/$REPO"

# ---------------------------------------------------------------- 1. hand-written intro
if [ -n "$INTRO" ] && [ -s "$INTRO" ]; then
    # drop the HTML maintainer comment on the first line
    sed '1{/^<!--.*-->$/d}' "$INTRO"
    echo
fi

# ---------------------------------------------------------------- 2. provenance
cat <<EOT
### This build

| | |
| --- | --- |
| release tag | \`${TAG:-TBD}\` |
| multigpu commit | [\`${MG_COMMIT:0:12}\`]($BASE_URL/commit/$MG_COMMIT) (branch \`multigpu\`) |
| upstream llama.cpp base | [\`${UP_COMMIT:0:12}\`](https://github.com/ggml-org/llama.cpp/commit/$UP_COMMIT) (${UP_DATE:0:10}) |
| commits ahead of upstream | $PATCH_COUNT (47 code patches indexed in [docs/multigpu/patches.md]($BASE_URL/blob/multigpu/docs/multigpu/patches.md), the rest docs/CI; full list below, also attached as \`-patches.tar.gz\`) |
EOT
for j in $(find "$META" -maxdepth 1 -name '*BUILD_INFO*.json' | sort); do
    flav="$(basename "$j" .json | sed 's/^BUILD_INFO-//')"
    echo "| toolchain \`$flav\` | CUDA $(get "$j" cuda_toolkit_version) ($(get "$j" cuda_nvcc)), $(get "$j" compiler), $(get "$j" cmake), $(get "$j" os) |"
done
echo

# ---------------------------------------------------------------- 3. downloads
cat <<'EOT'
### Downloads

Two Linux x86-64 CUDA flavours. Pick by GPU generation and installed driver; both carry the same code.

EOT
if [ -n "$MANIFEST" ] && [ -s "$MANIFEST" ]; then
    echo "| asset | CUDA | GPUs with native code (SASS) | PTX for other GPUs (JIT by the driver) | minimum driver | validation |"
    echo "| --- | --- | --- | --- | --- | --- |"
    while IFS=$'\t' read -r name flavour cuda sass ptx driver validation; do
        [ -n "${name:-}" ] || continue
        echo "| \`$name\` | ${cuda:--} | ${sass:--} | ${ptx:-none} | ${driver:--} | ${validation:-Tier A} |"
    done < "$MANIFEST"
    echo
fi
cat <<'EOT'
- **`cuda-12.9`**: the wide build. Native code for Volta (V100, `sm_70`), Ampere (`sm_86`), Ada (`sm_89`) and Blackwell
  (`sm_120a`/`sm_121a`); PTX for Maxwell, Pascal, Turing, A100 (`sm_80`) and Hopper (`sm_90`), which the driver compiles
  at first load. Needs an R525+ driver for the native targets, R570+ for Blackwell cards, and a driver that understands
  CUDA 12.9 PTX (R575+) for the PTX-only GPUs.
- **`cuda-13.4`**: Ampere and newer only (CUDA 13 dropped Maxwell/Pascal/Volta compilation). Native `sm_86`/`sm_89`/
  `sm_120a`/`sm_121a`, PTX for `sm_80`/`sm_90`. Needs an R580+ driver.
- `cudart-*`: the CUDA runtime + cuBLAS libraries matching each flavour, for hosts without a CUDA toolkit. Unpack next to
  the binaries (or set `LD_LIBRARY_PATH`). The NVIDIA driver (`libcuda.so.1`) always comes from the host.
- `patches.tar.gz`: the patch series as `git format-patch` output, for building upstream + selected patches.
- Container images: `ghcr.io/lukolszewski/llama.cpp-multigpu:server-cuda12.9-<tag>` and `:server-cuda13.4-<tag>`
  (`:latest` = cuda12.9), built from these very archives; run with `--gpus all`, `llama-server` is the entrypoint.

Validation: **Tier A** = the offline packaging gate passed in CI (archive unpacks, binaries run, the declared SASS/PTX
targets are really embedded, the downstream flags are wired, metadata matches the commit). **Tier B** = served a model on
real hardware; only Linux / `sm_86` (6 x RTX 3090) is run by the maintainer. Every other GPU architecture in these archives
is compiled, not run - reports from such hardware are welcome as issues (archive name, GPU model/count, driver).
`SHA256SUMS.txt` covers every asset; each archive embeds `BUILD_INFO.json` / `BUILD_INFO.txt`.

EOT

# ---------------------------------------------------------------- 4. patch list
echo "<details><summary><b>All $PATCH_COUNT commits ahead of upstream in this build</b> (code patches and docs/CI) - per-patch description and switches: <a href=\"$BASE_URL/blob/multigpu/docs/multigpu/patches.md\">docs/multigpu/patches.md</a></summary>"
echo
python3 - "$JSON" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
print("| commit | subject |")
print("| --- | --- |")
for p in d.get("patches", []):
    print("| `%s` | %s |" % (p.get("commit", "TBD"), p.get("subject", "TBD").replace("|", "\\|")))
PY
echo
echo "</details>"
echo
echo "License: MIT (upstream llama.cpp license preserved). Upstream llama.cpp is where this work belongs; this fork exists to be archived once upstream performs comparably."
