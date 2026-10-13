#!/usr/bin/env bash
# Live driver for verified secondmate slot-reconciliation teardown.
# Disposable Treehouse pools + marked lab homes only. Never --force on the
# records-only path. Never touches the operator default pool.
set -euo pipefail

ROOT=/Users/claytonjohnson/.no-mistakes/worktrees/dad68ef8e401/01M4SM9ANTVMP8FS6SBD31FS89
EV=/Users/claytonjohnson/.no-mistakes/evidence/01M4SM9ANTVMP8FS6SBD31FS89
TEARDOWN="$ROOT/bin/fm-teardown.sh"
LAB_HOME_SH="$ROOT/bin/fm-lab-home.sh"

run_teardown() {
  local lab=$1 id=$2
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE \
    -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE \
    -u FM_PROJECTS_OVERRIDE -u TREEHOUSE_ROOT -u TASKS_AXI_FILE \
    -u TASKS_AXI_BACKEND \
    FM_HOME="$lab" \
    "$TEARDOWN" "$id"
}

canonical() {
  ( cd "$1" && pwd -P )
}

write_meta() {
  local file=$1
  shift
  : > "$file"
  local kv
  for kv in "$@"; do
    printf '%s\n' "$kv" >> "$file"
  done
}

seed_lab() {
  local lab=$1 task=${2:-}
  cat > "$lab/.tasks.toml" <<'TOML'
backend = "markdown"

[markdown]
path = "data/backlog.md"
archive = "data/done-archive.md"
done_keep = 10
TOML
  {
    printf '%s\n' '# Backlog' '' '## In flight'
    if [ -n "$task" ]; then
      printf '%s\n' "- [ ] $task - obsolete ordinary task (repo: project) (kind: ship) (since 2026-01-01)"
    fi
    printf '%s\n' '' '## Queued' '' '## Done'
  } > "$lab/data/backlog.md"
}

make_repo() {
  local repo=$1
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid \
    commit --allow-empty -qm init
  ( cd "$repo" && treehouse init >/dev/null )
  python3 - "$repo" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1]) / "treehouse.toml"
text = p.read_text()
p.write_text(text.replace('root = ""', 'root = "."', 1))
PY
}

lease_slot() {
  local repo=$1 holder=$2
  ( cd "$repo" && treehouse get --lease --lease-holder "$holder" --json )
}

status_json() {
  local repo=$1
  ( cd "$repo" && treehouse status --json )
}

claim_slot() {
  local slot=$1 task=$2 home=$3
  printf 'task=%s\nhome=%s\n' "$task" "$home" > "$(dirname "$slot")/.fm-slot-owner"
}

cleanup_list=()
register() { cleanup_list+=("$1"); }
cleanup() {
  local p
  for p in "${cleanup_list[@]+"${cleanup_list[@]}"}"; do
    if [ -n "$p" ] && [ -d "$p" ]; then
      # Best-effort: stop leftover sleeps whose cwd is under the fixture.
      pkill -f "fm-live-slot-sleep:$p" 2>/dev/null || true
      rm -rf "$p"
    fi
  done
}
trap cleanup EXIT

fail_scenario() {
  echo "FAIL: $*" >&2
  return 1
}

# ---------------------------------------------------------------------------
# Scenario: stale ordinary-task records retire; leased secondmate preserved
# ---------------------------------------------------------------------------
happy_dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-live-happy.XXXXXX")
register "$happy_dir"
mkdir -p "$happy_dir/repo"
make_repo "$happy_dir/repo"
repo=$(canonical "$happy_dir/repo")
lab_raw=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
register "$lab_raw"
"$LAB_HOME_SH" create "$lab_raw" >/dev/null
lab=$(canonical "$lab_raw")
seed_lab "$lab" stale-task

lease_out=$(lease_slot "$repo" orbit-mate)
slot=$(printf '%s\n' "$lease_out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["path"])')
slot=$(canonical "$slot")
lease_id=$(printf '%s\n' "$lease_out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["lease_id"])')

git -C "$slot" checkout -q -b unpublished-work
printf 'keep-me\n' > "$slot/preserved.txt"
git -C "$slot" add preserved.txt
git -C "$slot" -c user.name=test -c user.email=test@example.invalid commit -qm unpublished
# A live process in the secondmate home must survive records-only cleanup.
( cd "$slot" && exec -a "fm-live-slot-sleep:$happy_dir" sleep 120 ) &
worker=$!

write_meta "$lab/state/stale-task.meta" \
  "worktree=$slot" "project=$repo" "kind=ship" "mode=local-only"
write_meta "$lab/state/orbit-mate.meta" \
  "kind=secondmate" "home=$slot" "worktree=$slot" "project=$repo"
printf '%s\n' "- orbit-mate - fixture (home: $slot; scope: test; projects: project; added 2026-01-01)" \
  > "$lab/data/secondmates.md"
claim_slot "$slot" stale-task "$lab"
marker_before=$(cat "$(dirname "$slot")/.fm-slot-owner")
status_before=$(status_json "$repo")
printf '%s\n' "$status_before" > "$EV/happy-status-before.json"
printf '%s\n' "$lease_out" > "$EV/happy-lease.json"
printf '%s\n' "$marker_before" > "$EV/happy-marker-before.txt"

set +e
run_teardown "$lab" stale-task > "$EV/happy-stdout.txt" 2> "$EV/happy-stderr.txt"
happy_rc=$?
set -e
status_after=$(status_json "$repo")
printf '%s\n' "$status_after" > "$EV/happy-status-after.json"
if [ -f "$(dirname "$slot")/.fm-slot-owner" ]; then
  cat "$(dirname "$slot")/.fm-slot-owner" > "$EV/happy-marker-after.txt"
else
  printf 'MISSING\n' > "$EV/happy-marker-after.txt"
fi
{
  echo "rc=$happy_rc"
  echo "stale_meta=$([ -f "$lab/state/stale-task.meta" ] && echo present || echo absent)"
  echo "secondmate_meta=$([ -f "$lab/state/orbit-mate.meta" ] && echo present || echo absent)"
  echo "preserved_file=$([ -f "$slot/preserved.txt" ] && echo present || echo absent)"
  echo "unpublished_branch=$(git -C "$slot" rev-parse --abbrev-ref HEAD 2>/dev/null || echo missing)"
  echo "worker_alive=$(kill -0 "$worker" 2>/dev/null && echo yes || echo no)"
  echo "slot_git=$([ -e "$slot/.git" ] && echo present || echo absent)"
  echo "marker_unchanged=$([ "$(cat "$EV/happy-marker-after.txt")" = "$marker_before" ] && echo yes || echo no)"
} > "$EV/happy-observations.txt"

kill "$worker" 2>/dev/null || true
wait "$worker" 2>/dev/null || true

python3 - "$EV" "$slot" "$lease_id" "$happy_rc" <<'PY'
import json, pathlib, sys
ev, slot, lease_id, rc = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3], int(sys.argv[4])
obs = dict(line.split("=",1) for line in (ev/"happy-observations.txt").read_text().splitlines())
after = json.loads((ev/"happy-status-after.json").read_text())
stderr = (ev/"happy-stderr.txt").read_text()
stdout = (ev/"happy-stdout.txt").read_text()
rows = [r for r in after if r.get("path")==slot]
ok = (
    rc == 0
    and obs["stale_meta"]=="absent"
    and obs["secondmate_meta"]=="present"
    and obs["preserved_file"]=="present"
    and obs["unpublished_branch"]=="unpublished-work"
    and obs["worker_alive"]=="yes"
    and obs["slot_git"]=="present"
    and obs["marker_unchanged"]=="yes"
    and len(rows)==1
    and rows[0].get("status")=="leased"
    and rows[0].get("lease_holder")=="orbit-mate"
    and rows[0].get("lease_id")==lease_id
    and "orbit-mate" in stderr
    and "only stale-task's own records will be retired" in stderr
    and "treehouse return" not in stderr.lower()
)
(ev/"happy-verdict.txt").write_text("pass\n" if ok else "fail\n")
if not ok:
    raise SystemExit("happy-path checks failed")
PY

# ---------------------------------------------------------------------------
# Scenario: non-leased in-use status with own claim still tears down
# ---------------------------------------------------------------------------
own_dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-live-own.XXXXXX")
register "$own_dir"
mkdir -p "$own_dir/repo"
make_repo "$own_dir/repo"
own_repo=$(canonical "$own_dir/repo")
own_lab_raw=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
register "$own_lab_raw"
"$LAB_HOME_SH" create "$own_lab_raw" >/dev/null
own_lab=$(canonical "$own_lab_raw")
seed_lab "$own_lab" owned-task

own_lease=$(lease_slot "$own_repo" owned-task)
own_slot=$(printf '%s\n' "$own_lease" | python3 -c 'import json,sys; print(json.load(sys.stdin)["path"])')
own_slot=$(canonical "$own_slot")
# Drop the durable lease so status is a non-leased pool row (the review fix).
( cd "$own_repo" && treehouse return --force "$own_slot" >/dev/null )
( cd "$own_slot" && exec -a "fm-live-slot-sleep:$own_dir" sleep 120 ) &
own_worker=$!
# Give treehouse a moment to observe the process.
sleep 0.3
own_status_before=$(status_json "$own_repo")
printf '%s\n' "$own_status_before" > "$EV/own-status-before.json"

write_meta "$own_lab/state/owned-task.meta" \
  "worktree=$own_slot" "project=$own_repo" "kind=ship" "mode=local-only"
claim_slot "$own_slot" owned-task "$own_lab"

set +e
run_teardown "$own_lab" owned-task > "$EV/own-stdout.txt" 2> "$EV/own-stderr.txt"
own_rc=$?
set -e
own_status_after=$(status_json "$own_repo")
printf '%s\n' "$own_status_after" > "$EV/own-status-after.json"
{
  echo "rc=$own_rc"
  echo "meta=$([ -f "$own_lab/state/owned-task.meta" ] && echo present || echo absent)"
  echo "marker=$([ -f "$(dirname "$own_slot")/.fm-slot-owner" ] && echo present || echo absent)"
  echo "stderr_refused=$(grep -c 'REFUSED: Treehouse reports a lease' "$EV/own-stderr.txt" || true)"
} > "$EV/own-observations.txt"
kill "$own_worker" 2>/dev/null || true
wait "$own_worker" 2>/dev/null || true

python3 - "$EV" "$own_slot" "$own_rc" <<'PY'
import json, pathlib, sys
ev, slot, rc = pathlib.Path(sys.argv[1]), sys.argv[2], int(sys.argv[3])
obs = dict(line.split("=",1) for line in (ev/"own-observations.txt").read_text().splitlines())
before = json.loads((ev/"own-status-before.json").read_text())
after = json.loads((ev/"own-status-after.json").read_text())
stderr = (ev/"own-stderr.txt").read_text()
rows_b = [r for r in before if r.get("path")==slot]
non_leased = rows_b and rows_b[0].get("status") in {"in-use","available","dirty","unverified"} and not rows_b[0].get("lease_id")
rows_a = [r for r in after if r.get("path")==slot]
returned = (not rows_a) or rows_a[0].get("status") in {"available","dirty","unverified"}
ok = (
    rc == 0
    and obs["meta"]=="absent"
    and obs["marker"]=="absent"
    and obs["stderr_refused"]=="0"
    and non_leased
    and "REFUSED: Treehouse reports a lease" not in stderr
)
(ev/"own-verdict.txt").write_text("pass\n" if ok else "fail\n")
(ev/"own-notes.txt").write_text(
    f"non_leased_before={non_leased} before={rows_b!r} after={rows_a!r} returned={returned}\n"
)
if not ok:
    raise SystemExit("own-claim non-leased teardown checks failed")
PY

# ---------------------------------------------------------------------------
# Adversarial: uncertain / contradictory ownership still refuses
# ---------------------------------------------------------------------------
adv_dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-live-adv.XXXXXX")
register "$adv_dir"
mkdir -p "$adv_dir/repo"
make_repo "$adv_dir/repo"
adv_repo=$(canonical "$adv_dir/repo")
adv_lab_raw=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
register "$adv_lab_raw"
"$LAB_HOME_SH" create "$adv_lab_raw" >/dev/null
adv_lab=$(canonical "$adv_lab_raw")
seed_lab "$adv_lab" stale-task

adv_lease=$(lease_slot "$adv_repo" unregistered-mate)
adv_slot=$(printf '%s\n' "$adv_lease" | python3 -c 'import json,sys; print(json.load(sys.stdin)["path"])')
adv_slot=$(canonical "$adv_slot")
printf 'keep-adversarial\n' > "$adv_slot/untouched.txt"
git -C "$adv_slot" add untouched.txt
git -C "$adv_slot" -c user.name=test -c user.email=test@example.invalid commit -qm adversarial
( cd "$adv_slot" && exec -a "fm-live-slot-sleep:$adv_dir" sleep 120 ) &
adv_worker=$!

write_meta "$adv_lab/state/stale-task.meta" \
  "worktree=$adv_slot" "project=$adv_repo" "kind=ship" "mode=local-only"
write_meta "$adv_lab/state/orbit-mate.meta" \
  "kind=secondmate" "home=$adv_slot" "worktree=$adv_slot" "project=$adv_repo"
printf '%s\n' "- orbit-mate - fixture (home: $adv_slot; scope: test; projects: project; added 2026-01-01)" \
  > "$adv_lab/data/secondmates.md"
claim_slot "$adv_slot" stale-task "$adv_lab"
printf '%s\n' "$(status_json "$adv_repo")" > "$EV/adv-unregistered-status-before.json"

set +e
run_teardown "$adv_lab" stale-task > "$EV/adv-unregistered-stdout.txt" 2> "$EV/adv-unregistered-stderr.txt"
adv_rc=$?
set -e
printf '%s\n' "$(status_json "$adv_repo")" > "$EV/adv-unregistered-status-after.json"
{
  echo "rc=$adv_rc"
  echo "stale_meta=$([ -f "$adv_lab/state/stale-task.meta" ] && echo present || echo absent)"
  echo "secondmate_meta=$([ -f "$adv_lab/state/orbit-mate.meta" ] && echo present || echo absent)"
  echo "file=$([ -f "$adv_slot/untouched.txt" ] && echo present || echo absent)"
  echo "worker_alive=$(kill -0 "$adv_worker" 2>/dev/null && echo yes || echo no)"
  echo "marker=$([ -f "$(dirname "$adv_slot")/.fm-slot-owner" ] && echo present || echo absent)"
} > "$EV/adv-unregistered-observations.txt"

python3 - "$EV" "$adv_rc" <<'PY'
import pathlib, sys
ev, rc = pathlib.Path(sys.argv[1]), int(sys.argv[2])
obs = dict(line.split("=",1) for line in (ev/"adv-unregistered-observations.txt").read_text().splitlines())
stderr = (ev/"adv-unregistered-stderr.txt").read_text()
ok = (
    rc != 0
    and obs["stale_meta"]=="present"
    and obs["secondmate_meta"]=="present"
    and obs["file"]=="present"
    and obs["worker_alive"]=="yes"
    and obs["marker"]=="present"
    and "nothing was changed" in stderr
)
(ev/"adv-unregistered-verdict.txt").write_text("pass\n" if ok else "fail\n")
if not ok:
    raise SystemExit("unregistered-holder refuse checks failed")
PY

# missing secondmate record while a real lease names orbit-mate
miss_dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-live-miss.XXXXXX")
register "$miss_dir"
mkdir -p "$miss_dir/repo"
make_repo "$miss_dir/repo"
miss_repo=$(canonical "$miss_dir/repo")
miss_lab_raw=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
register "$miss_lab_raw"
"$LAB_HOME_SH" create "$miss_lab_raw" >/dev/null
miss_lab=$(canonical "$miss_lab_raw")
seed_lab "$miss_lab" stale-task
miss_lease=$(lease_slot "$miss_repo" orbit-mate)
miss_slot=$(printf '%s\n' "$miss_lease" | python3 -c 'import json,sys; print(json.load(sys.stdin)["path"])')
miss_slot=$(canonical "$miss_slot")
printf 'keep-missing-record\n' > "$miss_slot/untouched.txt"
git -C "$miss_slot" add untouched.txt
git -C "$miss_slot" -c user.name=test -c user.email=test@example.invalid commit -qm missing-record
write_meta "$miss_lab/state/stale-task.meta" \
  "worktree=$miss_slot" "project=$miss_repo" "kind=ship" "mode=local-only"
printf '%s\n' "- orbit-mate - fixture (home: $miss_slot; scope: test; projects: project; added 2026-01-01)" \
  > "$miss_lab/data/secondmates.md"
claim_slot "$miss_slot" stale-task "$miss_lab"

set +e
run_teardown "$miss_lab" stale-task > "$EV/adv-missing-record-stdout.txt" 2> "$EV/adv-missing-record-stderr.txt"
miss_rc=$?
set -e
{
  echo "rc=$miss_rc"
  echo "stale_meta=$([ -f "$miss_lab/state/stale-task.meta" ] && echo present || echo absent)"
  echo "file=$([ -f "$miss_slot/untouched.txt" ] && echo present || echo absent)"
  echo "marker=$([ -f "$(dirname "$miss_slot")/.fm-slot-owner" ] && echo present || echo absent)"
  echo "lease_after=$(python3 -c 'import json,sys; rows=json.load(sys.stdin); print(rows[0]["status"]+"/"+rows[0].get("lease_holder",""))' <<<"$(status_json "$miss_repo")")"
} > "$EV/adv-missing-record-observations.txt"
python3 - "$EV" "$miss_rc" <<'PY'
import pathlib, sys
ev, rc = pathlib.Path(sys.argv[1]), int(sys.argv[2])
obs = dict(line.split("=",1) for line in (ev/"adv-missing-record-observations.txt").read_text().splitlines())
stderr = (ev/"adv-missing-record-stderr.txt").read_text()
ok = (
    rc != 0
    and obs["stale_meta"]=="present"
    and obs["file"]=="present"
    and obs["marker"]=="present"
    and obs["lease_after"].startswith("leased/")
    and "nothing was changed" in stderr
)
(ev/"adv-missing-record-verdict.txt").write_text("pass\n" if ok else "fail\n")
if not ok:
    raise SystemExit("missing-record refuse checks failed")
PY

# contradictory marker home
mark_dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-live-mark.XXXXXX")
register "$mark_dir"
mkdir -p "$mark_dir/repo"
make_repo "$mark_dir/repo"
mark_repo=$(canonical "$mark_dir/repo")
mark_lab_raw=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
register "$mark_lab_raw"
"$LAB_HOME_SH" create "$mark_lab_raw" >/dev/null
mark_lab=$(canonical "$mark_lab_raw")
seed_lab "$mark_lab" stale-task
other_home=$(mktemp -d "${TMPDIR:-/tmp}/fm-live-otherhome.XXXXXX")
register "$other_home"
mark_lease=$(lease_slot "$mark_repo" orbit-mate)
mark_slot=$(printf '%s\n' "$mark_lease" | python3 -c 'import json,sys; print(json.load(sys.stdin)["path"])')
mark_slot=$(canonical "$mark_slot")
printf 'keep-marker\n' > "$mark_slot/untouched.txt"
git -C "$mark_slot" add untouched.txt
git -C "$mark_slot" -c user.name=test -c user.email=test@example.invalid commit -qm marker
write_meta "$mark_lab/state/stale-task.meta" \
  "worktree=$mark_slot" "project=$mark_repo" "kind=ship" "mode=local-only"
write_meta "$mark_lab/state/orbit-mate.meta" \
  "kind=secondmate" "home=$mark_slot" "worktree=$mark_slot" "project=$mark_repo"
printf '%s\n' "- orbit-mate - fixture (home: $mark_slot; scope: test; projects: project; added 2026-01-01)" \
  > "$mark_lab/data/secondmates.md"
claim_slot "$mark_slot" stale-task "$other_home"

set +e
run_teardown "$mark_lab" stale-task > "$EV/adv-marker-stdout.txt" 2> "$EV/adv-marker-stderr.txt"
mark_rc=$?
set -e
{
  echo "rc=$mark_rc"
  echo "stale_meta=$([ -f "$mark_lab/state/stale-task.meta" ] && echo present || echo absent)"
  echo "file=$([ -f "$mark_slot/untouched.txt" ] && echo present || echo absent)"
  echo "marker=$([ -f "$(dirname "$mark_slot")/.fm-slot-owner" ] && echo present || echo absent)"
} > "$EV/adv-marker-observations.txt"
python3 - "$EV" "$mark_rc" <<'PY'
import pathlib, sys
ev, rc = pathlib.Path(sys.argv[1]), int(sys.argv[2])
obs = dict(line.split("=",1) for line in (ev/"adv-marker-observations.txt").read_text().splitlines())
stderr = (ev/"adv-marker-stderr.txt").read_text()
ok = (
    rc != 0
    and obs["stale_meta"]=="present"
    and obs["file"]=="present"
    and obs["marker"]=="present"
    and "nothing was changed" in stderr
)
(ev/"adv-marker-verdict.txt").write_text("pass\n" if ok else "fail\n")
if not ok:
    raise SystemExit("contradictory-marker refuse checks failed")
PY

kill "$adv_worker" 2>/dev/null || true
wait "$adv_worker" 2>/dev/null || true

echo ALL_LIVE_SCENARIOS_PASSED
