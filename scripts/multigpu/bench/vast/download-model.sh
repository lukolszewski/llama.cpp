#!/usr/bin/env bash
# =============================================================================
# download-model.sh — pull GGUF files straight off Hugging Face into $MODEL_DIR,
#                      with live progress on stdout (bench image, Vast.ai boxes).
#
# aria2c engine: 16 connections per file, skip complete files, resume partial
# ones, sha256 against the HF LFS oid, retry forever on transient errors.
# Originally written for the operator's private vast-cloud image (2026-10-03);
# this copy is the one the llama.cpp-multigpu bench image ships.
#
# HF_TOKEN is OPTIONAL: the default repo (unsloth/Qwen3.8-Flash-Next-GGUF) is
# public. Set it only for gated repos; it is the only secret this image accepts.
#
# WHAT IS FETCHED (default)
#   $QUANT/*.gguf                       4 shards, 111,334,654,784 B  (~103.7 GiB)
#   $MMPROJ          (USE_MMPROJ=1)     mmproj-BF16.gguf              907 MB
#   $MTP_HEAD        (MTP=1)            mtp-…-Q8_0.gguf               4.1 GB
#   HF_FILES="a.gguf b.gguf"            explicit repo paths instead of $QUANT/*
#                                       (rehearsals with a small model)
# Layout is flat in $MODEL_DIR, exactly what the run scripts expect:
#   llama.cpp finds the remaining shards of a split model by name in the same
#   directory as the -00001-of-0000N file it was given, so no subdir is created.
#
# RESTARTABLE: re-run it any time. A file whose size already equals the remote
# size is SKIPPED (sha256-checked if VERIFY=1 or if it is small); a partial file
# + its .aria2 control file is RESUMED; a checksum mismatch (aria2 exit 9) drops
# the file and refetches; any other error is retried every RETRY_WAIT s.
#
# ENV  HF_TOKEN (optional, never baked into the image)  HF_REPO  HF_REVISION
#      QUANT  HF_FILES  MODEL_DIR  USE_MMPROJ  MMPROJ  MTP  MTP_HEAD
#      ARIA_X=16  FILES_PAR=1  ARIA_SUMMARY=10  PROGRESS_INTERVAL=15
#      RETRIES=0(forever)  RETRY_WAIT=15  FORCE=1  VERIFY=1  DRY_RUN=1
#      INCLUDE_RE  EXCLUDE_RE  FILE_LIMIT=0(all)  MIN_FREE_GB=<computed>#      FLATTEN=1 (shards straight into $MODEL_DIR, like the run script expects)#      CONSOLE_LOG_LEVEL=warn  DRY_RUN=1
# =============================================================================
set -uo pipefail

HF_TOKEN="${HF_TOKEN:-}"
HF_REPO="${HF_REPO:-unsloth/Qwen3.8-Flash-Next-GGUF}"
HF_REVISION="${HF_REVISION:-main}"
HF_HOST="${HF_HOST:-https://huggingface.co}"

MODEL_DIR="${MODEL_DIR:-/models}"
QUANT="${QUANT:-UD-Q4_K_XL}"
USE_MMPROJ="${USE_MMPROJ:-0}"
HF_FILES="${HF_FILES:-}"
MMPROJ="${MMPROJ:-mmproj-BF16.gguf}"
MTP="${MTP:-0}"
MTP_HEAD="${MTP_HEAD:-MTP/mtp-Qwen3.8-Flash-Next-Q8_0.gguf}"

ARIA_X="${ARIA_X:-16}"                 # connections per file
FILES_PAR="${FILES_PAR:-1}"            # files at once (aria2c processes)
ARIA_SUMMARY="${ARIA_SUMMARY:-10}"     # s between aria2's own readout
PROGRESS_INTERVAL="${PROGRESS_INTERVAL:-15}"   # s between our aggregate lines
RETRIES="${RETRIES:-0}"                # 0 = forever
RETRY_WAIT="${RETRY_WAIT:-15}"
FORCE="${FORCE:-0}"
VERIFY="${VERIFY:-0}"
DRY_RUN="${DRY_RUN:-0}"
INCLUDE_RE="${INCLUDE_RE:-}"
EXCLUDE_RE="${EXCLUDE_RE:-}"
FILE_LIMIT="${FILE_LIMIT:-0}"
FLATTEN="${FLATTEN:-1}"
CONSOLE_LOG_LEVEL="${CONSOLE_LOG_LEVEL:-warn}"
MIN_FREE_GB="${MIN_FREE_GB:-}"

log() { echo "[$(date '+%F %T %Z')] $*"; }
die() { echo "[$(date '+%F %T %Z')] FATAL: $*" >&2; exit 1; }
fmt_h() { awk -v b="${1:-0}" 'BEGIN{split("B KB MB GB TB",u," ");i=1;b=b+0;
  while(b>=1024&&i<5){b/=1024;i++} printf (b>=100?"%.0f%s":"%.1f%s"), b, u[i]}'; }

command -v aria2c  >/dev/null 2>&1 || die "aria2c missing in this image"
command -v python3 >/dev/null 2>&1 || die "python3 missing in this image"
[ -n "$HF_TOKEN" ] || log "HF_TOKEN not set: anonymous download (fine for public repos such as $HF_REPO)"

# ---------------------------------------------------------------------------
# list_repo -> "path<TAB>size<TAB>sha256" for every file in the repo.
# One recursive call, Link-header pagination, stdlib only (same as lib.sh).
# ---------------------------------------------------------------------------
list_repo() {
  HF_TOKEN="$HF_TOKEN" HF_REPO="$HF_REPO" HF_REVISION="$HF_REVISION" HF_HOST="$HF_HOST" python3 - <<'PY'
import json, os, re, sys, urllib.request
repo, rev, host = os.environ["HF_REPO"], os.environ["HF_REVISION"], os.environ["HF_HOST"]
tok = os.environ["HF_TOKEN"]
url = f"{host}/api/models/{repo}/tree/{rev}?recursive=true"
hdr = {"Authorization": f"Bearer {tok}"} if tok else {}
while url:
    req = urllib.request.Request(url, headers=hdr)
    with urllib.request.urlopen(req, timeout=120) as r:
        data = json.load(r)
        link = r.headers.get("Link", "")
    for f in data:
        if f.get("type") != "file":
            continue
        lfs = f.get("lfs") or {}
        print(f"{f['path']}\t{lfs.get('size', f.get('size', 0)) or 0}\t{lfs.get('oid', '') or ''}")
    m = re.search(r'<([^>]+)>\s*;\s*rel="next"', link)
    url = m.group(1) if m else None
PY
}

# ---------------------------------------------------------------------------
# want() — the selection: every .gguf under $QUANT/ (sorted, so the -00001-of-
# -of- manifest order is kept and the shard set is contiguous), plus the
# sidecars the entrypoint was asked for. Then INCLUDE_RE/EXCLUDE_RE/FILE_LIMIT.
# ---------------------------------------------------------------------------
build_wishlist() {
  local all="$1"
  {
    if [ -n "$HF_FILES" ]; then
      local f
      for f in ${HF_FILES//,/ }; do
        printf '%s\n' "$all" | awk -F'\t' -v p="$f" '$1 == p {print}' | grep . || die "$f is not in $HF_REPO@$HF_REVISION"
      done
    else
    printf '%s\n' "$all" | awk -F'\t' -v d="$QUANT/" 'index($1, d) == 1 && $1 ~ /\.gguf$/ {print}' | sort
    fi
    if [ "$USE_MMPROJ" = "1" ] && [ -n "$MMPROJ" ]; then
      printf '%s\n' "$all" | awk -F'\t' -v p="$MMPROJ" '$1 == p {print}'
    fi
    if [ "$MTP" = "1" ]; then
      printf '%s\n' "$all" | awk -F'\t' -v p="$MTP_HEAD" '$1 == p {print}'
    fi
  } | awk -F'\t' -v inc="$INCLUDE_RE" -v exc="$EXCLUDE_RE" -v lim="$FILE_LIMIT" '
      NF < 2 { next }
      inc != "" && $1 !~ inc { next }
      exc != "" && $1 ~ exc { next }
      { c++; if (lim+0 == 0 || c <= lim+0) print }'
}

# ---------------------------------------------------------------------------
# fetch_one <path> <size> <sha256>   — skip / resume / verify / retry forever
# A parallel child is handed ONE="path<TAB>size<TAB>sha" and re-execs THIS script
# for that single file (see the bottom of the file) instead of exporting bash
# functions through an xargs command string.
# ---------------------------------------------------------------------------
fetch_one() {
  local path="$1" size="${2:-0}" oid="${3:-}"
  # FLATTEN=1 (default): "UD-Q4_K_XL/x.gguf" -> "$MODEL_DIR/x.gguf", i.e. the layout
  # run-qwen38-6x3090-260k.sh globs for. Other prefixes (MTP/) are kept: the script
  # passes /models/MTP/mtp-...gguf.
  local rel="$path"
  [ "$FLATTEN" = "1" ] && rel="${path#"$QUANT/"}"
  local tgt="$MODEL_DIR/$rel"
  local url="$HF_HOST/$HF_REPO/resolve/$HF_REVISION/$path?download=true"
  mkdir -p "$(dirname "$tgt")"

  if [ "$FORCE" != "1" ] && [ -f "$tgt" ]; then
    local now; now=$(stat -c %s "$tgt" 2>/dev/null || echo -1)
    if [ "$size" -gt 0 ] && [ "$now" -eq "$size" ]; then
      if [ -n "$oid" ] && { [ "$VERIFY" = "1" ] || [ "$size" -le 1048576 ]; }; then
        local got; got=$(sha256sum "$tgt" | cut -d' ' -f1)
        if [ "$got" = "$oid" ]; then log "SKIP $path ($(fmt_h "$size"), sha256 ok)"; return 0; fi
        log "HASH MISMATCH $path ($got != $oid) -> re-download"
        rm -f "$tgt" "$tgt.aria2"
      else
        log "SKIP $path ($(fmt_h "$size") complete; VERIFY=1 to re-hash)"; return 0
      fi
    fi
  fi

  if [ "$DRY_RUN" = "1" ]; then log "DRY: would fetch $path ($(fmt_h "$size")) -> $tgt"; return 0; fi

  local n=0 rc=0 t0 el
  while :; do
    n=$((n+1)); t0=$(date +%s)
    log "GET  $path [$(fmt_h "$size")] attempt $n -> $tgt"
    _via_aria "$url" "$tgt" "$oid" || rc=$?

    if [ "$rc" -eq 0 ]; then
      el=$(( $(date +%s) - t0 )); [ "$el" -le 0 ] && el=1
      log "DONE $path in ${el}s ($(fmt_h $(( size / el )))/s)  [$(fmt_h "$size")]"
      return 0
    fi

    log "ERR  $path (exit $rc) attempt $n"
    if [ "$rc" -eq 9 ]; then            # checksum mismatch: the bytes are wrong
      log "     sha256 mismatch -> dropping the file, restarting it from zero"
      rm -f "$tgt" "$tgt.aria2"
    fi
    if [ "$rc" -eq 3 ]; then            # 404: retrying forever is pointless
      die "$path not found in $HF_REPO@$HF_REVISION (404) — wrong QUANT/repo/revision?"
    fi
    if [ "$RETRIES" -gt 0 ] && [ "$n" -ge "$RETRIES" ]; then
      log "GIVEUP $path after $n attempts"; return 1
    fi
    sleep "$RETRY_WAIT"
  done
}

# aria2c, one file. Console readout + summary stay ON: that is the per-file bar
# in `docker logs -f`; the aggregate PROGRESS line below it comes from monitor().
_via_aria() {
  local url="$1" tgt="$2" oid="$3" ck=() auth=()
  [ -n "$oid" ] && ck=(--checksum=sha-256="$oid" --check-integrity=true)
  [ -n "$HF_TOKEN" ] && auth=(--header="Authorization: Bearer $HF_TOKEN")
  # console-log-level=warn on purpose: "notice" prints one ~2 KB signed xet-redirect
  # URL per connection (16/file) and buries the actual progress in `docker logs`.
  aria2c -d "$(dirname "$tgt")" -o "$(basename "$tgt")" \
    -c --auto-file-renaming=false --allow-overwrite=true \
    -x "$ARIA_X" -s "$ARIA_X" -k1M --min-split-size=1M --file-allocation=none \
    --max-tries=0 --retry-wait=10 --timeout=60 --connect-timeout=30 \
    --max-file-not-found=3 \
    --auto-save-interval=15 \
    --show-console-readout=true --summary-interval="$ARIA_SUMMARY" \
    --console-log-level="$CONSOLE_LOG_LEVEL" \
    "${auth[@]}" "${ck[@]}" "$url"
}

# ---------------------------------------------------------------------------
# monitor — one aggregate PROGRESS line every PROGRESS_INTERVAL s. Written for
# the non-TTY case (`docker logs`), where aria2c's bar is a moving block: this
# says "12.3 GB of 103.7 GB (11%), 96 MB/s, ETA 16m" in plain lines.
# ---------------------------------------------------------------------------
_pid=""
monitor_start() { # monitor_start <total_bytes> <paths-newline-list>
  local total="$1" list="$2"
  [ "$DRY_RUN" = "1" ] && return 0
  [ "${PROGRESS_INTERVAL:-15}" -gt 0 ] || return 0
  (
    local prev=0 now rate
    while :; do
      sleep "$PROGRESS_INTERVAL"
      now=$(printf '%s\n' "$list" | awk -F'\t' -v d="$MODEL_DIR" -v q="$QUANT/" -v flat="$FLATTEN" '
        NF>=1 { p=$1; if (flat=="1" && index(p,q)==1) p=substr(p,length(q)+1); f = d "/" p; cmd = "stat -c %s \"" f "\" 2>/dev/null"; cmd | getline s; close(cmd); s += 0; sum += s }
        END { print sum + 0 }')
      rate=$(( (now - prev) / PROGRESS_INTERVAL )); [ "$rate" -lt 0 ] && rate=0
      prev="$now"
      awk -v n="$now" -v t="$total" -v r="$rate" 'BEGIN{
        pct = (t > 0 ? n * 100.0 / t : 0);
        eta = (r > 0 ? (t - n) / r : -1);
        printf "[progress] %.2f GB / %.2f GB (%.1f%%)  %.1f MB/s  eta %s\n",
               n/1073741824, t/1073741824, pct, r/1048576,
               (eta < 0 ? "-" : sprintf("%dm%02ds", int(eta/60), int(eta%60)))}';
    done
  ) &
  _pid=$!
}
monitor_stop() { [ -n "${_pid:-}" ] && kill "$_pid" >/dev/null 2>&1 || true; _pid=""; }
trap monitor_stop EXIT

# ---------------------------------------------------------------------------
main() {
  mkdir -p "$MODEL_DIR"
  log "##### download: $HF_REPO @ $HF_REVISION -> $MODEL_DIR (engine=aria2c x$ARIA_X, files_par=$FILES_PAR) #####"

  local all; all="$(list_repo)" || die "cannot list $HF_REPO (gated repo without HF_TOKEN? network?)"
  local want; want="$(build_wishlist "$all")"
  local n bytes
  n=$(printf '%s\n' "$want" | grep -c . || true)
  bytes=$(printf '%s\n' "$want" | awk -F'\t' '{s+=$2} END{printf "%d", s+0}')
  [ "$n" -gt 0 ] || die "nothing matched in $HF_REPO (QUANT=$QUANT USE_MMPROJ=$USE_MMPROJ MTP=$MTP INCLUDE_RE='${INCLUDE_RE}' EXCLUDE_RE='${EXCLUDE_RE}' FILE_LIMIT=$FILE_LIMIT)"

  log "PLAN $n files, $(fmt_h "$bytes") (quant=$QUANT mmproj=$USE_MMPROJ mtp=$MTP parallel=$FILES_PAR)"
  printf '%s\n' "$want" | awk -F'\t' '{printf "     %-62s %8.2f GB\n", $1, $2/1073741824}' | head -12
  [ "$n" -gt 12 ] && log "     … ($n files total, first 12 shown)"

  # free-space guard: what we still need, +10% headroom (markers/logs/inflight)
  local have need got
  need=$(( bytes + bytes / 10 ))
  have=$(df -B1 --output=avail "$MODEL_DIR" 2>/dev/null | tail -1 | tr -dc '0-9')
  got=$(( ${have:-0} / 1073741824 ))
  local want_gb=${MIN_FREE_GB:-$(( need / 1073741824 ))}
  if [ "${DRY_RUN}" != "1" ] && [ -n "$have" ] && [ "$got" -lt "$want_gb" ]; then
    die "not enough disk for $HF_REPO: $want_gb GB needed on $MODEL_DIR, $got GB free (override: MIN_FREE_GB=1)"
  fi
  log "disk check: $got GB free on $MODEL_DIR (${want_gb} GB wanted)"

  monitor_start "$bytes" "$want"
  local fail=0 rc p s o
  if [ "$FILES_PAR" -gt 1 ] && [ "$DRY_RUN" != "1" ]; then
    # smallest first (early wins), at most $FILES_PAR aria2c processes alive
    local running=0
    while IFS=$'\t' read -r p s o; do
      [ -z "$p" ] && continue
      while [ "$running" -ge "$FILES_PAR" ]; do wait -n; running=$((running-1)); done
      ONE="$p	$s	$o" "$0" & running=$((running+1))
    done < <(printf '%s\n' "$want" | sort -t$'\t' -k2,2n)
    wait || fail=1
  else
    while IFS=$'\t' read -r p s o; do
      [ -z "$p" ] && continue
      fetch_one "$p" "$s" "$o" || fail=1
    done <<< "$want"
  fi
  monitor_stop

  [ "$fail" -eq 0 ] || { log "download FAILED: at least one file did not complete"; return 1; }
  [ "$DRY_RUN" = "1" ] && { log "dry run: nothing was fetched"; return 0; }
  local ondisk
  ondisk=$(printf '%s\n' "$want" | awk -F'\t' -v d="$MODEL_DIR" -v q="$QUANT/" -v flat="$FLATTEN" '
    NF>=1 { p=$1; if (flat=="1" && index(p,q)==1) p=substr(p,length(q)+1); f = d "/" p; cmd = "stat -c %s \"" f "\" 2>/dev/null"; cmd | getline s; close(cmd); sum += s+0 }
    END { printf "%d", sum+0 }')
  log "download finished: $n files, $(fmt_h "$ondisk") / $(fmt_h "$bytes") present in $MODEL_DIR"
  [ "$ondisk" -ge "$bytes" ] || { log "FATAL: still short of the planned bytes"; return 1; }
  return 0
}

# ONE=<path\tsize\tsha>  ->  fetch just that one file and quit. `exit`, so the
# child never re-lists the repo (the parent already did that once).
if [ -n "${ONE:-}" ]; then
  IFS=$'\t' read -r _p _s _o <<< "$ONE"
  mkdir -p "$MODEL_DIR"
  fetch_one "$_p" "$_s" "$_o"; exit $?
fi

main "$@"
