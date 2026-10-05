#!/usr/bin/env bash
# Tier A: packaging / integrity gate for a llama.cpp-multigpu artifact.
#
# This runs with NO GPU and NO driver and deliberately claims nothing about hardware behaviour. It
# answers one question: does the archive contain what its metadata says it contains? Runtime
# validation on real hardware is Tier B (scripts/multigpu/bench/runtime-smoke.sh).
#
# Checks:
#   1. archive unpacks, expected files present (llama-server, BUILD_INFO.json/txt, LICENSE, AUTHORS)
#   2. llama-server executes: --version and --help (with the archive dir on the library path)
#   3. dynamic dependencies resolve
#   4. the CUDA fatbin contains the declared device architectures: SASS (cuobjdump --list-elf) and, for
#      forward-compatible "virtual" targets, PTX (cuobjdump --list-ptx) - both offline, no driver
#   5. the downstream patchset's CLI switches are wired into this binary (a rebase that silently
#      dropped a patch fails here)
#   6. BUILD_INFO.json is valid and names both the multigpu commit and an upstream base commit
#
# Usage:
#   scripts/multigpu/validate-artifact.sh --archive FILE.tar.gz [--expect-arch sm_86,sm_89]
#                                         [--expect-ptx sm_50,sm_61,...] [--expect-no-ptx]
#                                         [--expect-flags --prefill-max-partial,...]
#                                         [--expect-commit SHA] [--keep]
#
# --expect-arch lists the SASS (real) architectures that must be embedded; --expect-ptx lists the PTX
# (virtual) targets; --expect-no-ptx asserts the archive carries no PTX at all (sm_86-only CI images).
# Names follow cuobjdump: `sm_70`, `sm_120a`; PTX entries are listed by cuobjdump as `<lib>.N.sm_XX.ptx`.

set -euo pipefail

ARCHIVE=""
EXPECT_ARCH=""
EXPECT_PTX=""
EXPECT_NO_PTX=""
EXPECT_FLAGS="--prefill-max-partial,--prefill-long-threshold,--prefill-max-long,--seq-compact,--cache-idle-slots"
EXPECT_COMMIT=""
KEEP=""
WORKDIR=""

while [ $# -gt 0 ]; do
    case "$1" in
        --archive)       ARCHIVE="$2"; shift 2 ;;
        --expect-arch)   EXPECT_ARCH="$2"; shift 2 ;;
        --expect-ptx)    EXPECT_PTX="$2"; shift 2 ;;
        --expect-no-ptx) EXPECT_NO_PTX=1; shift ;;
        --expect-flags)  EXPECT_FLAGS="$2"; shift 2 ;;
        --expect-commit) EXPECT_COMMIT="$2"; shift 2 ;;
        --keep)          KEEP=1; shift ;;
        -h|--help)       grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "validate-artifact: unknown argument: $1" >&2; exit 1 ;;
    esac
done

[ -n "$ARCHIVE" ] || { echo "validate-artifact: --archive is required" >&2; exit 1; }
[ -f "$ARCHIVE" ] || { echo "validate-artifact: no such file: $ARCHIVE" >&2; exit 1; }

fail=0
note()  { printf '  [ok]   %s\n' "$1"; }
bad()   { printf '  [FAIL] %s\n' "$1"; fail=1; }
skip()  { printf '  [skip] %s\n' "$1"; }

WORKDIR="$(mktemp -d)"
trap '[ -n "$KEEP" ] || rm -rf "$WORKDIR"' EXIT

echo "== Tier A gate: $(basename "$ARCHIVE")"

# ---------------------------------------------------------------- 1. unpack
echo "-- unpack"
case "$ARCHIVE" in
    *.tar.gz|*.tgz) tar -xzf "$ARCHIVE" -C "$WORKDIR" ;;
    *.zip)          python3 -c "import sys,zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" "$ARCHIVE" "$WORKDIR" ;;
    *) bad "unsupported archive type: $ARCHIVE"; exit 1 ;;
esac
note "archive unpacked"

BIN="$(find "$WORKDIR" -type f -name 'llama-server*' ! -name '*.so*' ! -name '*.dll' | head -1 || true)"
[ -n "$BIN" ] || { bad "no llama-server found in the archive"; exit 1; }
BINDIR="$(dirname "$BIN")"
note "llama-server at ${BINDIR#"$WORKDIR"/}"

# ---------------------------------------------------------------- 2. metadata files
echo "-- metadata and license presence"
for f in BUILD_INFO.json BUILD_INFO.txt LICENSE AUTHORS; do
    if [ -e "$BINDIR/$f" ]; then note "$f present"; else bad "$f missing from the archive"; fi
done
if command -v jq >/dev/null 2>&1 && [ -f "$BINDIR/BUILD_INFO.json" ]; then
    if jq -e . "$BINDIR/BUILD_INFO.json" > /dev/null; then note "BUILD_INFO.json parses"; else bad "BUILD_INFO.json is not valid JSON"; fi
    for key in multigpu_commit upstream_base_commit cuda_architectures platform backend; do
        val="$(jq -r ".${key} // \"<missing>\"" "$BINDIR/BUILD_INFO.json")"
        if [ "$val" = "<missing>" ] || [ -z "$val" ]; then
            bad "BUILD_INFO.json has no .$key"
        else
            note ".$key = $val"
        fi
    done
    if [ -n "$EXPECT_COMMIT" ]; then
        got="$(jq -r .multigpu_commit "$BINDIR/BUILD_INFO.json")"
        case "$got" in "$EXPECT_COMMIT"*) note "commit matches $EXPECT_COMMIT";; *) bad "commit $got != expected $EXPECT_COMMIT";; esac
    fi
else
    skip "jq unavailable: JSON schema check skipped"
fi

# ---------------------------------------------------------------- 3. executes + deps
echo "-- execution (no GPU involved)"
export LD_LIBRARY_PATH="$BINDIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
if "$BIN" --version > "$WORKDIR/version.txt" 2>&1; then
    note "llama-server --version: $(head -1 "$WORKDIR/version.txt")"
else
    bad "llama-server --version exited non-zero"
    sed 's/^/      /' "$WORKDIR/version.txt" | head -20
fi
if "$BIN" --help > "$WORKDIR/help.txt" 2>&1; then
    note "llama-server --help OK"
else
    bad "llama-server --help exited non-zero"
    sed 's/^/      /' "$WORKDIR/help.txt" | head -20
fi

if command -v ldd >/dev/null 2>&1 && [ -x "$BIN" ]; then
    if ldd "$BIN" 2>/dev/null | grep -q "not found"; then
        bad "unresolved dynamic dependencies: $(ldd "$BIN" | awk '/not found/{print $1}' | tr '\n' ' ')"
    else
        note "ldd: no missing libraries"
    fi
else
    skip "ldd unavailable or binary is not a POSIX executable"
fi

# ---------------------------------------------------------------- 4. downstream switches
echo "-- downstream switch wiring"
IFS=',' read -r -a flags <<< "$EXPECT_FLAGS"
for flag in "${flags[@]}"; do
    [ -n "$flag" ] || continue
    if grep -q -- "$flag" "$WORKDIR/help.txt"; then
        note "$flag advertised (its patch is in this build)"
    else
        bad "$flag missing - a downstream patch is not in this binary"
    fi
done

# ---------------------------------------------------------------- 5. CUDA device code
echo "-- CUDA device code (offline inspection, no driver needed)"
CUDA_LIB="$(find "$WORKDIR" -type f \( -name 'libggml-cuda.so*' -o -name 'ggml-cuda.so*' -o -name 'ggml-cuda*.dll' \) | head -1 || true)"
if [ -n "$CUDA_LIB" ] && command -v cuobjdump >/dev/null 2>&1; then
    elf_list="$(cuobjdump --list-elf "$CUDA_LIB" 2>/dev/null || true)"
    if [ -z "$elf_list" ]; then
        # Fall back to the fatbin section listing if the ELF table is unavailable.
        elf_list="$(cuobjdump --list-text "$CUDA_LIB" 2>/dev/null || true)"
    fi
    ptx_list="$(cuobjdump --list-ptx "$CUDA_LIB" 2>/dev/null || true)"
    if [ -z "$elf_list" ]; then
        bad "cuobjdump produced no device-code listing for $(basename "$CUDA_LIB")"
    else
        # cuobjdump names entries "<lib>.<n>.sm_86.cubin" / "<lib>.<n>.sm_50.ptx"; collect the unique targets.
        # (|| true: grep exits 1 when a list is empty, e.g. no PTX in a SASS-only build; that is data, not an error)
        sass_detected="$(printf '%s\n' "$elf_list" | grep -oE 'sm_[0-9]+[a-f]?' | sort -u || true)"
        ptx_detected="$(printf '%s\n' "$ptx_list" | grep -oE 'sm_[0-9]+[a-f]?' | sort -u || true)"
        note "SASS present: $(printf '%s' "$sass_detected" | tr '\n' ' ')"
        note "PTX present:  $(printf '%s' "${ptx_detected:-none}" | tr '\n' ' ')"
        if [ -n "$EXPECT_ARCH" ]; then
            IFS=',' read -r -a arches <<< "$EXPECT_ARCH"
            for a in "${arches[@]}"; do
                [ -n "$a" ] || continue
                if printf '%s\n' "$sass_detected" | grep -qx -- "$a"; then
                    note "declared SASS architecture $a is embedded"
                else
                    bad "declared SASS architecture $a is NOT embedded (metadata overstates GPU support)"
                fi
            done
        fi
        if [ -n "$EXPECT_PTX" ]; then
            IFS=',' read -r -a ptxes <<< "$EXPECT_PTX"
            for a in "${ptxes[@]}"; do
                [ -n "$a" ] || continue
                if printf '%s\n' "$ptx_detected" | grep -qx -- "$a"; then
                    note "declared PTX target $a is embedded (JIT on the driver at load time)"
                else
                    bad "declared PTX target $a is NOT embedded (forward compatibility claim is false)"
                fi
            done
        fi
        if [ -n "$EXPECT_NO_PTX" ]; then
            if [ -z "$ptx_detected" ]; then
                note "no PTX embedded, as declared (real architectures only)"
            else
                bad "PTX is embedded although the build was declared SASS-only: $(printf '%s' "$ptx_detected" | tr '\n' ' ')"
            fi
        fi
    fi
elif [ -n "$CUDA_LIB" ]; then
    skip "cuobjdump unavailable; falling back to embedded arch strings"
    detected="$(strings "$CUDA_LIB" 2>/dev/null | grep -oE 'sm_[0-9]+[a-f]?' | sort -u | tr '\n' ',' || true)"
    note "strings-detected architectures: ${detected:-none} (weaker than cuobjdump)"
    [ -z "$EXPECT_PTX" ] || bad "--expect-ptx needs cuobjdump; run the gate inside the nvidia/cuda devel image"
else
    # A gate that silently skips its main check is worse than one that fails: if the caller declared
    # which device architectures the artifact must contain, the absence of CUDA device code is a
    # packaging error, not something to shrug at.
    if [ -n "$EXPECT_ARCH$EXPECT_PTX" ]; then
        bad "no CUDA backend library found in the archive, but --expect-arch/--expect-ptx was given"
    else
        skip "no CUDA backend library in this archive (CPU-only build?)"
    fi
fi

# ---------------------------------------------------------------- 6. weights must not ship
echo "-- archive hygiene"
if find "$WORKDIR" -type f -name '*.gguf' | grep -q .; then
    bad "a .gguf model file is present in the artifact - archives must stay weights-free"
else
    note "no model weights shipped"
fi
if find "$WORKDIR" -type f -name 'LICENSE' | grep -q .; then
    note "upstream license shipped with the binaries"
fi

echo
if [ "$fail" -eq 0 ]; then
    echo "Tier A gate PASSED. Note: this says nothing about runtime behaviour on a GPU - see Tier B."
else
    echo "Tier A gate FAILED"
fi
exit "$fail"
