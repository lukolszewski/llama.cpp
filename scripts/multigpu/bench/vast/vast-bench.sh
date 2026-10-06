#!/usr/bin/env bash
# =============================================================================
# vast-bench.sh — rent a multi-GPU machine on Vast.ai, run the README benchmark grid there with the
# llama.cpp-multigpu bench image, bring the raw results back over SSH, destroy the instance, and land
# the results in this repository as a pull request. Documentation: README.md next to this file.
#
#   vast-bench.sh search  --gpu RTX_4090 --num-gpus 6 [filters]          # free: show what is rentable
#   vast-bench.sh run     --gpu RTX_4090 --num-gpus 6 --max-usd 6 ...    # the whole pipeline
#   vast-bench.sh status  [--instance ID]                                # what is running, what it costs
#   vast-bench.sh fetch   --instance ID [--dest DIR]                     # copy /results from a live instance
#   vast-bench.sh land    --results DIR [--machine-name NAME] [--no-pr] [--base multigpu]  # results dir -> branch + PR
#   vast-bench.sh destroy --instance ID | --cleanup                      # destroy one / every mgbench-* instance
#
# Rules this script enforces (docs/multigpu/benchmarks.md, plan-vast-bench): no GitHub credential ever
# reaches the rented machine (results come back over SSH, the workstation commits); the only secret that
# may be passed is HF_TOKEN and only when --hf-token-env names it; spend is capped (--max-usd, --max-hours)
# and checked against the account credit; the instance is destroyed on every exit path of `run`
# (success, failure, timeout, Ctrl-C) unless --keep; numbers are never typed, every table is generated
# from the JSON the grid wrote.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FORK_DIR="${FORK_DIR:-$(cd "$HERE/../../../.." && pwd)}"
STATE_DIR="${MGBENCH_STATE_DIR:-$HOME/.cache/mgbench}"
mkdir -p "$STATE_DIR"

# ---- defaults ----------------------------------------------------------------
CMD="run"
GPU=""; NUM_GPUS=""; GPU_RAM_MIN=""; MAX_DPH=""; MAX_USD="10"; MAX_HOURS="5"
OFFER=""; IMAGE="${MGBENCH_IMAGE:-ghcr.io/lukolszewski/llama.cpp-multigpu:bench-cuda12.9}"
UPSTREAM=0; UPSTREAM_SIZES=""; UPSTREAM_SLOTS=""
SIZES="5000,50000,150000,200000,250000"; SLOTS="1,5"
MACHINE_NAME=""; DISK="180"; HF_TOKEN_ENV=""; EXTRA_ENV=""; EXTRA_QUERY=""
MIN_INET="800"; MIN_CPU_RAM="48"; MIN_DISK="160"; MIN_VRAM_GB="140"; MIN_RELIABILITY="0.95"; INGRESS_GB="115"
BOOT_TIMEOUT="1800"; SSH_TIMEOUT="600"; POLL="60"
DRY_RUN=0; KEEP=0; NO_LAND=0; NO_PR=0; INSTANCE=""; RESULTS=""; DEST=""; CLEANUP=0; ALLOW_DIRTY=0; BASE_BRANCH="multigpu"
MIN_PP="300"; MIN_TG="5"; KEEP_ON_FAIL=1; MACHINE_ID=""
SSH_KEY="${MGBENCH_SSH_KEY:-$HOME/.ssh/vastai_ed25519}"
LABEL_PREFIX="mgbench"

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
case "${1:-}" in search|run|status|fetch|land|destroy) CMD="$1"; shift ;; -h|--help) usage ;; esac
while [ $# -gt 0 ]; do
  case "$1" in
    --gpu) GPU="$2"; shift 2 ;;              --num-gpus) NUM_GPUS="$2"; shift 2 ;;
    --gpu-ram-min) GPU_RAM_MIN="$2"; shift 2 ;; --max-dph) MAX_DPH="$2"; shift 2 ;;
    --max-usd) MAX_USD="$2"; shift 2 ;;      --max-hours) MAX_HOURS="$2"; shift 2 ;;
    --offer) OFFER="$2"; shift 2 ;;          --image) IMAGE="$2"; shift 2 ;;
    --upstream) UPSTREAM=1; shift ;;         --no-upstream) UPSTREAM=0; shift ;;
    --upstream-sizes) UPSTREAM_SIZES="$2"; shift 2 ;; --upstream-slots) UPSTREAM_SLOTS="$2"; shift 2 ;;
    --sizes) SIZES="$2"; shift 2 ;;          --slots) SLOTS="$2"; shift 2 ;;
    --machine-name) MACHINE_NAME="$2"; shift 2 ;; --disk) DISK="$2"; shift 2 ;;
    --hf-token-env) HF_TOKEN_ENV="$2"; shift 2 ;; --env) EXTRA_ENV="$EXTRA_ENV $2"; shift 2 ;;
    --query) EXTRA_QUERY="$EXTRA_QUERY $2"; shift 2 ;;
    --min-inet) MIN_INET="$2"; shift 2 ;;    --min-cpu-ram) MIN_CPU_RAM="$2"; shift 2 ;;
    --min-disk) MIN_DISK="$2"; shift 2 ;;    --min-vram) MIN_VRAM_GB="$2"; shift 2 ;;
    --min-reliability) MIN_RELIABILITY="$2"; shift 2 ;; --ingress-gb) INGRESS_GB="$2"; shift 2 ;;
    --boot-timeout) BOOT_TIMEOUT="$2"; shift 2 ;; --ssh-timeout) SSH_TIMEOUT="$2"; shift 2 ;; --poll) POLL="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;           --keep) KEEP=1; shift ;;
    --no-land) NO_LAND=1; shift ;;           --no-pr) NO_PR=1; shift ;;
    --instance) INSTANCE="$2"; shift 2 ;;    --results) RESULTS="$2"; shift 2 ;;
    --dest) DEST="$2"; shift 2 ;;            --cleanup) CLEANUP=1; shift ;;
    --fork-dir) FORK_DIR="$2"; shift 2 ;;    --ssh-key) SSH_KEY="$2"; shift 2 ;;
    --allow-dirty) ALLOW_DIRTY=1; shift ;;   --base) BASE_BRANCH="$2"; shift 2 ;;
    --min-pp) MIN_PP="$2"; shift 2 ;;        --min-tg) MIN_TG="$2"; shift 2 ;;
    --no-repair) KEEP_ON_FAIL=0; shift ;;    --machine-id) MACHINE_ID="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "unknown argument: $1" >&2; usage 2 ;;
  esac
done
[ "$CMD" = run ] && [ "$DRY_RUN" = 1 ] && CMD=search

ts() { date '+%F %T'; }
log() { echo "[$(ts)] $*"; }
die() { echo "[$(ts)] ERROR: $*" >&2; exit "${2:-1}"; }
need() { command -v "$1" >/dev/null 2>&1 || die "$1 is required"; }
need vastai; need python3; need ssh; need jq
py() { python3 -c "$@"; }
vast_json() { vastai "$@" --raw 2>/dev/null; }

# ---- offers ------------------------------------------------------------------
# PTX-only GPUs (Turing: sm_75) need a driver that knows CUDA 12.9 PTX; everything else runs cudart 12.9 on R525+.
cuda_floor() { case "$1" in RTX_2080*|RTX_20*|GTX_16*|Quadro_RTX*|Tesla_T4|T4) echo 12.9 ;; *) echo 12.0 ;; esac; }
search_offers() {
  [ -n "$GPU" ] && [ -n "$NUM_GPUS" ] || die "--gpu NAME --num-gpus N are required (names as Vast spells them: RTX_4090, RTX_5090, Tesla_V100, RTX_2080_Ti, RTX_6000Ada, RTX_PRO_6000_S)"
  local q="num_gpus=$NUM_GPUS gpu_name=$GPU disk_space>=$MIN_DISK cpu_ram>=$MIN_CPU_RAM inet_down>=$MIN_INET cuda_vers>=$(cuda_floor "$GPU") reliability>=$MIN_RELIABILITY rentable=true verified=true direct_port_count>=2"
  [ -n "$GPU_RAM_MIN" ] && q="$q gpu_ram>=$GPU_RAM_MIN"
  [ -n "$MAX_DPH" ] && q="$q dph<=$MAX_DPH"
  [ -n "$MACHINE_ID" ] && q="$q machine_id=$MACHINE_ID"   # same physical box as an earlier run (A/B on identical hardware)
  q="$q$EXTRA_QUERY"
  log "vastai search offers '$q' -o dph"
  OFFERS_JSON="$(vast_json search offers "$q" -o dph)" || die "vastai search failed"
  OFFERS_JSON="$(printf '%s' "$OFFERS_JSON" | MINV="$MIN_VRAM_GB" python3 -c '
import json, os, sys
d = json.load(sys.stdin); minv = float(os.environ["MINV"]) * 1024
print(json.dumps([o for o in d if (o.get("gpu_total_ram") or 0) >= minv]))')"
  printf '%s' "$OFFERS_JSON" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print("%d offer(s) after the VRAM filter; cheapest first:" % len(d))
hdr = ("offer", "machine", "gpu", "n", "VRAM GB", "$/h", "down Mb/s", "CUDA", "driver", "PCIe", "rel", "location")
fmt = "  %9s %7s %-14s %2s %7s %6s %9s %5s %-11s %-7s %5s  %s"
print(fmt % hdr)
for o in d[:10]:
    print(fmt % (o["id"], o["machine_id"], o["gpu_name"], o["num_gpus"], "%.0f" % (o["gpu_total_ram"] / 1024), "%.2f" % o["dph_total"],
                 "%.0f" % o["inet_down"], o["cuda_max_good"], o.get("driver_version"), "g%sx%s" % (o.get("pci_gen"), o.get("gpu_lanes")),
                 "%.3f" % o["reliability2"], o.get("geolocation")))'
}
pick_offer() {   # sets OFFER_JSON for --offer ID or the cheapest match
  if [ -n "$OFFER" ]; then
    OFFER_JSON="$(printf '%s' "$OFFERS_JSON" | jq -c --argjson id "$OFFER" '.[] | select(.id == $id)')"
    [ -n "$OFFER_JSON" ] || die "offer $OFFER is not in the filtered list above (gone, or outside the filters)" 2
  else
    OFFER_JSON="$(printf '%s' "$OFFERS_JSON" | jq -c '.[0] // empty')"
    [ -n "$OFFER_JSON" ] || die "no offer within the filters/budget" 2
  fi
  O_ID=$(jq -r .id <<<"$OFFER_JSON"); O_DPH=$(jq -r .dph_total <<<"$OFFER_JSON"); O_MACHINE=$(jq -r .machine_id <<<"$OFFER_JSON")
  O_GPU=$(jq -r .gpu_name <<<"$OFFER_JSON"); O_N=$(jq -r .num_gpus <<<"$OFFER_JSON"); O_VRAM=$(jq -r '.gpu_total_ram/1024|floor' <<<"$OFFER_JSON")
  O_STORAGE=$(jq -r '.storage_cost // 0' <<<"$OFFER_JSON"); O_INETC=$(jq -r '.inet_down_cost // 0' <<<"$OFFER_JSON")
  O_CUDA=$(jq -r .cuda_max_good <<<"$OFFER_JSON"); O_DRIVER=$(jq -r .driver_version <<<"$OFFER_JSON")
}
budget_check() {
  local credit; credit="$(vast_json show user | jq -r '.credit // 0')"
  EST="$(py "print(round($O_DPH*$MAX_HOURS + $DISK*$O_STORAGE/730*$MAX_HOURS + $INGRESS_GB*$O_INETC, 2))")"
  log "offer $O_ID: $O_N x $O_GPU ($O_VRAM GB), \$$O_DPH/h + disk + $INGRESS_GB GB ingress at \$$O_INETC/GB -> worst case \$$EST for $MAX_HOURS h; credit \$$credit; cap \$$MAX_USD"
  py "import sys; sys.exit(0 if $EST <= $MAX_USD else 1)" || die "worst-case cost \$$EST exceeds --max-usd $MAX_USD (lower --max-hours, pick a cheaper offer, or raise the cap)" 2
  py "import sys; sys.exit(0 if $EST <= $credit - 0.5 else 1)" || die "worst-case cost \$$EST exceeds the account credit \$$credit minus a \$0.50 margin" 2
}

# ---- instance ----------------------------------------------------------------
state_file() { echo "$STATE_DIR/instance-$1.json"; }
save_state() { jq -n --arg id "$INSTANCE" --arg lbl "$LABEL" --arg offer "$O_ID" --arg dph "$O_DPH" --arg machine "$O_MACHINE" \
  --arg gpu "$O_GPU" --arg n "$O_N" --arg name "$MACHINE_NAME" --arg t0 "$(date -u +%FT%TZ)" --arg image "$IMAGE" \
  '{"instance":$id,"label":$lbl,"offer":$offer,"dph":$dph,"machine_id":$machine,"gpu":$gpu,"num_gpus":$n,"machine_name":$name,"created":$t0,"image":$image}' > "$(state_file "$INSTANCE")"; }

ssh_target() {   # prints "port host" for the instance
  local url; url="$(vastai ssh-url "$1" 2>/dev/null | tr -d '\r' | tail -1)"
  [[ "$url" =~ ssh://([^@]+)@([^:]+):([0-9]+) ]] || return 1
  echo "${BASH_REMATCH[3]} ${BASH_REMATCH[2]}"
}
SSH_OPTS=(-o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=20 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ServerAliveInterval=30)
rssh() { local id="$1"; shift; local t; t="$(ssh_target "$id")" || return 255; set -- "$@"; ssh "${SSH_OPTS[@]}" -i "$SSH_KEY" -p ${t%% *} root@${t##* } "$@"; }

destroy_instance() {
  local id="$1"
  [ -n "$id" ] || return 0
  local out; out="$(vastai destroy instance "$id" -y 2>&1)"; log "destroy $id: $(echo "$out" | tail -1)"
  for _ in 1 2 3 4 5 6; do
    sleep 5
    vast_json show instances | jq -e --argjson id "$id" '.[] | select(.id == $id)' >/dev/null 2>&1 || { log "instance $id is gone"; rm -f "$(state_file "$id")"; return 0; }
  done
  log "WARNING: instance $id still listed after destroy; check 'vastai show instances' and the Vast console"
  return 1
}
billed_summary() {
  local id="$1" t0="$2" dph="$3"
  local secs=$(( $(date +%s) - t0 ))
  log "instance $id billed ~$((secs/60)) min at \$$dph/h ≈ \$$(py "print(round($secs/3600*$dph, 2))") (+ disk/bandwidth)"
}

# ---- fetch + run dir naming --------------------------------------------------
fetch_results() {   # fetch_results ID DEST
  local id="$1" dest="$2"
  mkdir -p "$dest"
  log "fetching /results from instance $id -> $dest"
  rssh "$id" 'tar -C /results -czf - .' | tar -xzf - -C "$dest" || return 1
  ls -la "$dest" | sed 's/^/   /'
}
run_dir_name() {   # from a results dir: <date>-grid-<up7>-vs-<mg7> or <date>-grid-<mg7>-only
  local d="$1" mg up
  mg="$(jq -r '.multigpu_commit[0:7]' "$d/BUILD_INFO.json" 2>/dev/null)"; up="$(jq -r '.upstream_base_commit[0:7]' "$d/BUILD_INFO.json" 2>/dev/null)"
  local day; day="$(date -r "$d/grid-multigpu.json" +%F 2>/dev/null || date +%F)"
  if [ -f "$d/grid-upstream.json" ]; then echo "$day-grid-$up-vs-$mg"; else echo "$day-grid-$mg-only"; fi
}
next_machine_name() {   # machine-NN-<n>x<gpu>
  local n="$1" gpu="$2" last
  last="$(ls -d "$FORK_DIR"/benches/multi-gpu/machine-[0-9][0-9]-* 2>/dev/null | sed -E 's/.*machine-([0-9]+)-.*/\1/' | sort -n | tail -1)"
  printf 'machine-%02d-%sx%s' "$(( ${last:-1} + 1 ))" "$n" "$(echo "$gpu" | tr 'A-Z' 'a-z' | tr -d ' _-')"
}

# ---- land: results dir -> branch, docs, PR -----------------------------------
land_results() {   # land_results RESULTS_DIR MACHINE_NAME
  local src="$1" name="$2"
  [ -f "$src/grid-multigpu.json" ] || die "$src has no grid-multigpu.json"
  [ -f "$src/DONE" ] || log "WARNING: $src has no DONE marker (partial run?) - landing what is there"
  cd "$FORK_DIR" || die "no fork dir $FORK_DIR"
  [ "$ALLOW_DIRTY" = 1 ] || [ -z "$(git status --porcelain)" ] || die "$FORK_DIR has uncommitted changes; commit/stash them or pass --allow-dirty"
  local run; run="$(run_dir_name "$src")"
  local day="${run%%-grid-*}" branch="bench/$name-${run%%-grid-*}"
  local mdir="benches/multi-gpu/$name" rdir="benches/multi-gpu/$name/$run"
  git fetch -q origin "$BASE_BRANCH"
  git checkout -q -b "$branch" "origin/$BASE_BRANCH" || die "cannot create branch $branch (exists?)"
  mkdir -p "$rdir"
  cp -a "$src"/. "$rdir"/
  rm -f "$rdir/onstart.log" "$rdir/.booted" "$rdir/.onstart"
  [ -f "$rdir/hardware.md" ] && cp "$rdir/hardware.md" "$mdir/hardware.md"
  # tables are generated from the JSON, never typed
  local up="-"; [ -f "$rdir/grid-upstream.json" ] && up="$rdir/grid-upstream.json"
  python3 scripts/multigpu/bench/readme_table.py "$up" "$rdir/grid-multigpu.json" > "$rdir/grid-table.md"
  if [ "$up" != "-" ]; then
    python3 scripts/multigpu/bench/plot-grid.py "$up" "$rdir/grid-multigpu.json" -o "$rdir/grid.svg" \
      --note "$name · $(jq -r '.gpus|length' "$rdir/hardware.json") × $(jq -r '.gpus[0].name' "$rdir/hardware.json") · $(jq -r .PARALLEL "$rdir/config.json") slots × $(( $(jq -r .CTX "$rdir/config.json") / $(jq -r .PARALLEL "$rdir/config.json") )) ctx · $(jq -r .KV_TYPE "$rdir/config.json") KV · $day" 2>/dev/null || true
  fi
  python3 - "$rdir" "$name" "$run" "$day" <<'PY'
import json, os, re, sys
rdir, name, run, day = sys.argv[1:5]
hw = json.load(open(f"{rdir}/hardware.json")); cfg = json.load(open(f"{rdir}/config.json")); bi = json.load(open(f"{rdir}/BUILD_INFO.json"))
M = json.load(open(f"{rdir}/grid-multigpu.json")); U = json.load(open(f"{rdir}/grid-upstream.json")) if os.path.exists(f"{rdir}/grid-upstream.json") else None
gpus = hw["gpus"]; gname = gpus[0]["name"] if gpus else "TBD"; n = len(gpus)
vram = sum(int(g["memory_total"].split()[0]) for g in gpus) // 1024
commits = open(f"{rdir}/COMMITS.txt").read().strip()
table = open(f"{rdir}/grid-table.md").read().strip()
upline = f"upstream {bi['upstream_base_commit'][:9]} (same cuda-12.9 recipe, baseline prerelease)" if U else "upstream: **not measured on this machine** (patched side only)"
def pick(d, slots, key):
    rows = [r for r in d["rows"] if r["slots"] == slots and key in r]
    return max(rows, key=lambda r: r["size_tokens"]) if rows else None
# --- docs/multigpu/benchmarks.md: a section per machine, inserted before "## Mixed workload behavior"
p = "docs/multigpu/benchmarks.md"; s = open(p).read()
sec = f"""### {name} (rented, Vast.ai)

```
multigpu commit:  {bi['multigpu_commit']}  (image {bi.get('backend')}, CUDA {bi.get('cuda_toolkit_version')}; SASS {bi.get('cuda_sass')}; PTX {bi.get('cuda_ptx')})
{commits.splitlines()[1] if len(commits.splitlines()) > 1 else ''}
{commits.splitlines()[2] if len(commits.splitlines()) > 2 else ''}
machine:          {n} x {gname} ({vram} GB aggregate){'' if not cfg.get('DEVICES') or len(cfg['DEVICES'].split(',')) == n else f", GPUs used: {cfg['DEVICES']} ({len(cfg['DEVICES'].split(','))} of {n})"}, driver {hw.get('driver_version')} (CUDA {hw.get('driver_cuda_version')}), CPU {hw['cpu']['model']}, RAM {hw.get('ram_total_gib')} GiB; record: benches/multi-gpu/{name}/hardware.md
server:           -c {cfg['CTX']} --parallel {cfg['PARALLEL']} -fa {cfg['FA']} --cache-type-k/v {cfg['KV_TYPE']} -b {cfg['BATCH']} -ub {cfg['UBATCH']} --tensor-split {cfg['TENSOR_SPLIT'] or '<none>'} (patched adds --prefill-max-partial {cfg['PREFILL_MAX_PARTIAL']} and LLAMA_DECODE_PIPELINE={cfg['DECODE_PIPELINE']} LLAMA_SERVER_GROUPS={cfg['SERVER_GROUPS']} LLAMA_PIPELINE_PARALLEL={cfg['PIPELINE_PARALLEL']} GGML_CUDA_GRAPHS_FORCE={cfg['GRAPHS_FORCE']} LLAMA_ATTN_ROT_DISABLE={cfg['ATTN_ROT_DISABLE']}; speculation off)
grid:             slots {cfg['GRID_SLOTS']}, sizes {cfg['GRID_SIZES']}{'' if not U else f"; upstream slots {cfg['UPSTREAM_GRID_SLOTS']}, sizes {cfg['UPSTREAM_GRID_SIZES']}"}; same protocol and scripts as machine-01
measured:         {day}; {upline}
raw data:         {rdir}/
```

{table}

"""
marker = "## Mixed workload behavior"
if f"### {name} (rented" in s:
    s = re.sub(rf"### {re.escape(name)} \(rented, Vast\.ai\)\n.*?(?=\n### |\n---\n)", sec.rstrip("\n") + "\n", s, count=1, flags=re.S)
else:
    s = s.replace("\n---\n\n" + marker, "\n" + sec + "---\n\n" + marker, 1)
open(p, "w").write(s)
# --- README: rented-machines table between the markers (header created on first use)
p = "README.md"; s = open(p).read()
b, e = "<!-- rented-machines:begin -->", "<!-- rented-machines:end -->"
if b in s and e in s:
    body = s[s.index(b) + len(b):s.index(e)]
    pp1 = pick(M, 1, "pp_slot_mean"); tgN = pick(M, max(r["slots"] for r in M["rows"]), "tg_slot_mean")
    def cell(rm, key, ru, fmt):
        if rm is None: return "not run"
        v = fmt(rm[key])
        if ru is not None: v = f"{fmt(ru[key])} → {v} ({rm[key]/ru[key]:.1f}×)"
        return v
    upp1 = pick(U, 1, "pp_slot_mean") if U else None; utgN = pick(U, tgN["slots"], "tg_slot_mean") if (U and tgN) else None
    used = len(cfg['DEVICES'].split(',')) if cfg.get('DEVICES') else n
    gcell = f"{used} of {n} × {gname} ({vram} GB in the box)" if used != n else f"{n} × {gname} ({vram} GB)"
    row = (f"| [{name}](benches/multi-gpu/{name}/hardware.md) | {gcell} | "
           f"{cell(pp1, 'pp_slot_mean', upp1, lambda v: f'{v:.0f}')} at {pp1['size_tokens']//1000}k | "
           f"{cell(tgN, 'tg_slot_mean', utgN, lambda v: f'{v:.1f}')} per session, {tgN['slots']} sessions at {tgN['size_tokens']//1000}k | "
           f"{'yes' if U else 'no'} | [{run}]({rdir}/) |")
    if "| machine |" not in body:
        body = ("\n\nOther machines (rented, one run each; same protocol, generated from the raw JSON by `vast-bench.sh land`; "
                "upstream = the fork's upstream base built with the same recipe when measured):\n\n"
                "| machine | GPUs | prefill, 1 session (t/s) | generation, concurrent sessions (t/s) | upstream measured | run |\n"
                "| --- | --- | --- | --- | --- | --- |\n")
    body = body.rstrip("\n") + "\n" + row + "\n"
    s = s[:s.index(b) + len(b)] + body + s[s.index(e):]
    open(p, "w").write(s)
print(f"docs updated for {name} / {run}")
PY
  git add "$mdir" docs/multigpu/benchmarks.md README.md
  local gpus; gpus="$(jq -r '"\(.gpus|length) x \(.gpus[0].name)"' "$rdir/hardware.json")"
  git commit -q -m "bench: $name grid $day ($gpus, Vast.ai)

Raw results, hardware record and generated table for $run.
Machine record: $mdir/hardware.md. Protocol: docs/multigpu/benchmarks.md." || die "nothing to commit?"
  log "committed on $branch"
  if [ "$NO_PR" = 1 ]; then log "--no-pr: branch $branch is local; push and open the PR yourself"; return 0; fi
  git push -q -u origin "$branch" || die "push failed"
  local body; body="$(printf '%s\n\n%s\n\n%s\n' "Benchmark grid from a rented machine (\`vast-bench.sh\`), $gpus. Review the hardware record, the server command line in \`config.json\`/\`bench.log\` and the raw JSON before merging; nothing in the tables was typed by hand." "$(cat "$rdir/COMMITS.txt")" "$(cat "$rdir/grid-table.md")")"
  local repo; repo="$(git remote get-url origin | sed -E 's#.*github.com[:/]##; s#\.git$##')"   # explicit: gh would otherwise target the fork's parent
  gh pr create -R "$repo" --base "$BASE_BRANCH" --head "$branch" --title "bench: $name ($gpus) grid $day" --body "$body" || die "gh pr create failed (branch is pushed)"
}

# =============================================================================
case "$CMD" in
  search)
    search_offers; exit 0 ;;
  status)
    vast_json show instances | jq -r '.[] | "\(.id)\t\(.label // "-")\t\(.actual_status // .cur_state)\t\(.num_gpus) x \(.gpu_name)\t$\(.dph_total)/h\t\(.ssh_host // "-"):\(.ssh_port // "-")\tstart \(.start_date // 0 | todate)"'
    ls "$STATE_DIR"/instance-*.json 2>/dev/null | sed 's/^/state: /'
    [ -z "$INSTANCE" ] || { rssh "$INSTANCE" 'cat /results/DONE /results/FAILED 2>/dev/null; echo "--- bench.log tail"; tail -n 15 /results/bench.log 2>/dev/null'; }
    exit 0 ;;
  fetch)
    [ -n "$INSTANCE" ] || die "--instance ID required"
    DEST="${DEST:-$STATE_DIR/results-$INSTANCE}"; fetch_results "$INSTANCE" "$DEST" || die "fetch failed"; log "results in $DEST"; exit 0 ;;
  land)
    [ -n "$RESULTS" ] || die "--results DIR required"
    if [ -z "$MACHINE_NAME" ]; then
      MACHINE_NAME="$(next_machine_name "$(jq -r '.gpus|length' "$RESULTS/hardware.json")" "$(jq -r '.gpus[0].name' "$RESULTS/hardware.json" | sed 's/NVIDIA //; s/GeForce //')")"
      log "machine name not given -> $MACHINE_NAME"
    fi
    land_results "$RESULTS" "$MACHINE_NAME"; exit 0 ;;
  destroy)
    if [ "$CLEANUP" = 1 ]; then
      ids="$(vast_json show instances | jq -r --arg p "$LABEL_PREFIX-" '.[] | select((.label // "") | startswith($p)) | .id')"
      for f in "$STATE_DIR"/instance-*.json; do [ -f "$f" ] && ids="$ids $(jq -r .instance "$f")"; done
      ids="$(echo $ids | tr ' ' '\n' | sort -u | grep . || true)"
      [ -n "$ids" ] || { log "nothing to clean up"; exit 0; }
      for id in $ids; do destroy_instance "$id"; done; exit 0
    fi
    [ -n "$INSTANCE" ] || die "--instance ID or --cleanup"
    destroy_instance "$INSTANCE"; exit $? ;;
  run) ;;
esac

# ============================================================== run: the pipeline
[ -f "$SSH_KEY" ] || die "ssh key $SSH_KEY not found (the key registered in the Vast account; --ssh-key)"
[ "$NO_LAND" = 1 ] || [ "$ALLOW_DIRTY" = 1 ] || [ -z "$(git -C "$FORK_DIR" status --porcelain)" ] || die "$FORK_DIR has uncommitted changes; landing would fail at the end. Commit/stash, or --no-land / --allow-dirty"
search_offers
pick_offer
budget_check
[ -n "$MACHINE_NAME" ] || MACHINE_NAME="$(next_machine_name "$O_N" "$O_GPU")"
LABEL="$LABEL_PREFIX-$(date +%Y%m%d-%H%M%S)"
SIDES="multigpu"; [ "$UPSTREAM" = 1 ] && SIDES="multigpu,upstream"

# container environment -> onstart command (no GitHub credential; HF token only if asked for)
ENVS=(RESULTS_DIR=/results MACHINE_NAME="$MACHINE_NAME" BENCH_SIDES="$SIDES" GRID_SLOTS="$SLOTS" GRID_SIZES="$SIZES" MIN_VRAM_GB="$MIN_VRAM_GB")
[ -n "$UPSTREAM_SIZES" ] && ENVS+=(UPSTREAM_GRID_SIZES="$UPSTREAM_SIZES")
[ -n "$UPSTREAM_SLOTS" ] && ENVS+=(UPSTREAM_GRID_SLOTS="$UPSTREAM_SLOTS")
for kv in $EXTRA_ENV; do ENVS+=("$kv"); done
if [ -n "$HF_TOKEN_ENV" ]; then tok="${!HF_TOKEN_ENV:-}"; [ -n "$tok" ] || die "--hf-token-env $HF_TOKEN_ENV is empty"; ENVS+=(HF_TOKEN="$tok"); fi
for kv in "${ENVS[@]}"; do case "$kv" in *GITHUB*|*GH_TOKEN*|*ghp_*|*gho_*) die "refusing to send a GitHub credential to a rented machine ($kv)";; esac; done
ENV_STR="$(printf '%q ' "${ENVS[@]}")"
ONSTART="mkdir -p /results; touch /results/.booted; (env $ENV_STR nohup /usr/local/bin/entrypoint.sh bench > /results/onstart.log 2>&1 &) ; echo started > /results/.onstart"

log "machine name: $MACHINE_NAME | image: $IMAGE | sides: $SIDES | slots: $SLOTS | sizes: $SIZES | disk: ${DISK} GB | label: $LABEL"
log "onstart: $(echo "$ONSTART" | sed -E 's/HF_TOKEN=[^ ]+/HF_TOKEN=***/')"

INSTANCE=""; T0=$(date +%s); EXIT_CODE=0
cleanup() {
  local rc=$?
  trap - EXIT INT TERM
  if [ -n "$INSTANCE" ]; then
    if [ "$KEEP" = 1 ] || { [ "$KEEP_ON_FAIL" = 1 ] && [ "${EXIT_CODE:-$rc}" = 4 ]; }; then
      log "instance $INSTANCE LEFT RUNNING for repair in place (\$$O_DPH/h!): $(ssh_target "$INSTANCE" | awk '{print "ssh -i '"$SSH_KEY"' -o IdentitiesOnly=yes -p "$1" root@"$2}')"
      log "   repair, then restart with the printed 'onstart:' env line + SKIP_DOWNLOAD=1; fetch/land with: $0 fetch --instance $INSTANCE; $0 land --results ...; destroy with: $0 destroy --instance $INSTANCE (--no-repair disables this)"
    else destroy_instance "$INSTANCE"; fi
    billed_summary "$INSTANCE" "$T0" "$O_DPH"
  fi
  exit "${EXIT_CODE:-$rc}"
}
trap cleanup EXIT; trap 'EXIT_CODE=130; exit 130' INT TERM

CREATE="$(vastai create instance "$O_ID" --image "$IMAGE" --disk "$DISK" --ssh --direct --cancel-unavail --label "$LABEL" --onstart-cmd "$ONSTART" --raw 2>&1)" \
  || { echo "$CREATE"; EXIT_CODE=3; die "vastai create instance failed" 3; }
INSTANCE="$(printf '%s' "$CREATE" | python3 -c 'import json,sys; t=sys.stdin.read(); d=json.loads(t[t.index("{"):]); print(d.get("new_contract") or "")' 2>/dev/null)"
[ -n "$INSTANCE" ] || { echo "$CREATE"; EXIT_CODE=3; die "no instance id in the create response" 3; }
save_state
log "instance $INSTANCE created (offer $O_ID, machine $O_MACHINE, $O_N x $O_GPU, driver $O_DRIVER / CUDA $O_CUDA); state: $(state_file "$INSTANCE")"

# 1. running
t=$(date +%s)
STARTS=0
while :; do
  J="$(vast_json show instance "$INSTANCE")"; ST="$(jq -r '.actual_status // "?"' <<<"$J")"; MSG="$(jq -r '.status_msg // ""' <<<"$J" | tr '\n' ' ' | cut -c1-120)"
  INT="$(jq -r '.intended_status // "?"' <<<"$J")"
  [ "$ST" = running ] && break
  # Vast creates a STOPPED instance when the offer vanished between search and create (or the host refused);
  # it would sit there forever. One start attempt, then give up.
  if [ "$INT" = stopped ] && [ $(( $(date +%s) - t )) -gt 60 ]; then
    if [ "$STARTS" -eq 0 ]; then STARTS=1; log "  instance is intended=stopped (offer gone or host refused); trying 'vastai start instance'"; vastai start instance "$INSTANCE" >/dev/null 2>&1 || true
    elif [ $(( $(date +%s) - t )) -gt 240 ]; then EXIT_CODE=3; die "instance stays stopped (intended_status=stopped) - the offer was not actually available; rerun to pick another" 3; fi
  fi
  [ $(( $(date +%s) - t )) -lt "$BOOT_TIMEOUT" ] || { EXIT_CODE=3; die "instance not running after ${BOOT_TIMEOUT}s (status $ST: $MSG)" 3; }
  log "  status=$ST $MSG"; sleep 20
done
log "instance running after $(( $(date +%s) - t ))s"
log "ssh-url: $(vastai ssh-url "$INSTANCE" 2>&1 | tr -d '\r' | tail -1) | public_ipaddr=$(jq -r '.public_ipaddr // "-"' <<<"$J") ports=$(jq -c '.ports // {}' <<<"$J" | cut -c1-200)"

# 2. ssh reachable and onstart fired
t=$(date +%s)
until out="$(rssh "$INSTANCE" 'cat /results/.onstart 2>/dev/null; nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader 2>/dev/null | head -1' 2>/dev/null)" && [ -n "$out" ]; do
  if [ $(( $(date +%s) - t )) -ge "$SSH_TIMEOUT" ]; then
    log "ssh never answered; last ssh error:"; rssh "$INSTANCE" true 2>&1 | tail -3 | sed 's/^/   /'
    log "instance logs (vastai logs, tail):"; vastai logs "$INSTANCE" --tail 40 2>&1 | tail -40 | sed 's/^/   | /'
    EXIT_CODE=5; die "ssh/onstart not reachable after ${SSH_TIMEOUT}s" 5
  fi
  sleep 15
done
log "ssh ok: $(echo "$out" | tail -1)"
grep -q started <<<"$out" || log "WARNING: onstart marker missing; waiting for it in the poll loop"

# 3. poll until DONE/FAILED, streaming bench.log
SEEN=0; t=$(date +%s); MAX_S=$(py "print(int($MAX_HOURS*3600))"); FAILS=0
while :; do
  if out="$(rssh "$INSTANCE" "tail -n +$((SEEN+1)) /results/bench.log 2>/dev/null; echo '@@MARK@@'; cat /results/DONE 2>/dev/null; cat /results/FAILED 2>/dev/null | sed 's/^/FAILED: /'; ls /results/.onstart >/dev/null 2>&1 || echo NO-ONSTART" 2>/dev/null)"; then
    FAILS=0
    logpart="${out%%@@MARK@@*}"; marks="${out#*@@MARK@@}"
    if [ -n "$logpart" ]; then printf '%s\n' "$logpart" | grep -v '^\s*$' | sed 's/^/   | /'; SEEN=$(( SEEN + $(printf '%s\n' "$logpart" | grep -c '') )); fi
    if grep -q '^FAILED:' <<<"$marks"; then log "remote reported FAILED: $(grep '^FAILED:' <<<"$marks" | head -1)"; EXIT_CODE=4; break; fi
    # sanity on the first grid rows: CPU-speed numbers are not results, stop paying for them
    row="$(printf '%s\n' "$logpart" | grep -E ' slots=[0-9]+ size=[0-9]+ pn=' | head -1 || true)"
    if [ -n "$row" ]; then
      pp="$(sed -nE 's/.*pp_agg=([0-9.]+).*/\1/p' <<<"$row")"; tg="$(sed -nE 's/.*tg_agg=([0-9.]+).*/\1/p' <<<"$row")"
      if py "import sys; sys.exit(0 if float('${pp:-0}') < float('$MIN_PP') or float('${tg:-0}') < float('$MIN_TG') else 1)"; then
        log "ABORT: first grid row is below the sanity floor (pp_agg=${pp:-?} < $MIN_PP or tg_agg=${tg:-?} < $MIN_TG t/s): the GPUs are not doing the work. Check grid-*-server.log."
        EXIT_CODE=4; break
      fi
    fi
    if grep -q ' ok ' <<<"$marks"; then log "remote DONE: $(grep ' ok ' <<<"$marks" | head -1)"; break; fi
    if grep -q NO-ONSTART <<<"$marks" && [ $(( $(date +%s) - t )) -gt 600 ]; then log "onstart never ran; starting the bench over ssh"; rssh "$INSTANCE" "$ONSTART" >/dev/null 2>&1 || true; fi
  else
    FAILS=$((FAILS+1)); log "  ssh poll failed ($FAILS)"; [ "$FAILS" -lt 10 ] || { EXIT_CODE=5; log "ssh unreachable for 10 polls"; break; }
  fi
  [ $(( $(date +%s) - T0 )) -lt "$MAX_S" ] || { log "TIMEOUT: --max-hours $MAX_HOURS reached"; EXIT_CODE=6; break; }
  sleep "$POLL"
done

# 4. fetch whatever exists (also on failure: the logs are the evidence)
DEST="${DEST:-$STATE_DIR/results-$INSTANCE}"
fetch_results "$INSTANCE" "$DEST" || log "WARNING: fetch failed"
log "results: $DEST"
[ "$EXIT_CODE" = 0 ] || { log "run ended with code $EXIT_CODE; not landing. Inspect $DEST/bench.log"; exit "$EXIT_CODE"; }

# 5. destroy now (the trap would too) so the clock stops before the slow git/PR step
destroy_instance "$INSTANCE"; billed_summary "$INSTANCE" "$T0" "$O_DPH"; INSTANCE=""

# 6. land
[ "$NO_LAND" = 1 ] && { log "--no-land: done. Land later with: $0 land --results $DEST --machine-name $MACHINE_NAME"; exit 0; }
land_results "$DEST" "$MACHINE_NAME"
