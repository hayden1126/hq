#!/usr/bin/env bash
# Test suite for hq. Plain shell, no dependencies: every test runs against a
# throwaway $HOME so nothing can touch the real one.
#
#   ./test/run.sh          run all
#   ./test/run.sh <name>   run one
#
# Tests source lib/hq.sh from the per-test sandbox ($T/hq), a runtime path the
# linter cannot resolve statically, so disable its "can't follow source" check:
# shellcheck disable=SC1091
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILED=()

# Each test runs in a subshell (see the runner), so the counters cannot live in
# shell variables. Tally files survive the subshell and let a test that aborts
# mid-way still be reported instead of taking the runner down with it.
TALLY="$(mktemp -d)"
trap 'rm -rf "$TALLY"' EXIT
: > "$TALLY/pass"; : > "$TALLY/fail"

fail() { printf '  \033[31m✗\033[0m %s\n' "$*"; printf 'x\n' >> "$TALLY/fail"; }
pass() { printf 'x\n' >> "$TALLY/pass"; }
count() { wc -l < "$TALLY/$1"; }

assert_eq() {
    if [[ "$1" == "$2" ]]; then pass; else fail "${3:-assertion}: expected '$2', got '$1'"; fi
}
assert_ok()      { if "$@" >/dev/null 2>&1; then pass; else fail "expected success: $*"; fi; }
assert_fails()   { if "$@" >/dev/null 2>&1; then fail "expected failure: $*"; else pass; fi; }
assert_dir()     { if [[ -d "$1" ]]; then pass; else fail "expected directory: $1"; fi; }
assert_no_dir()  { if [[ ! -e "$1" ]]; then pass; else fail "expected gone: $1"; fi; }
assert_contains(){ if grep -qF "$2" "$1" 2>/dev/null; then pass; else fail "expected '$2' in $1"; fi; }

# Fresh sandbox: a temp $HOME with its own copy of the repo.
setup() {
    T="$(mktemp -d)"
    cp -r "$REPO" "$T/hq"
    rm -f "$T/hq/REGISTRY.md" "$T/hq/FLOWS.md" "$T/hq/SOURCES.md" "$T/hq/pending-cc-migration.tsv"
    rm -rf "$T/hq/.state.git"
    export HOME="$T" HQ_ROOT="$T/hq"
    # $HOME is the sandbox, so git has no identity; tests that commit need one.
    export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid \
           GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
    unset HQ_ASSUME_CLAUDE_RUNNING
    BIN="$T/hq/bin"
    cd /                       # never run a move from inside the tree under test
    # Tests that `source lib/hq.sh` inherit its `set -euo pipefail`, which would
    # otherwise leak into every later test and abort the runner on the first
    # non-zero status. Each test starts from the harness's own options.
    set +e; set -uo pipefail
}
teardown() { [[ -n "${T:-}" && "$T" == /tmp/* ]] && rm -rf "$T"; }

seed_registry() {
    cat > "$T/hq/REGISTRY.md" <<REG
# Registry

## demo
- path: demo
- status: active
- docs: STATUS.md
- summary: A demo project.

## other
- path: code/other
- status: active
- summary: Another one.
REG
}

seed_sources() {
    cat > "$T/hq/SOURCES.md" <<SRC
# Sources

## gmail-demo
- kind: gmail
- server: gw-demo
- access: read
SRC
}

seed_flows() {
    cat > "$T/hq/FLOWS.md" <<FLW
# Flows

## good-flow
- source: gw-demo
- target: demo
- direction: source -> target
- scope: the demo inbox
- governance: target-rules

## dead-target
- source: gw-demo
- target: nosuch
- direction: source -> target
- governance: target-rules

## dead-source
- source: gw-ghost
- target: demo
- direction: source -> target
- governance: target-rules
FLW
}

# --- tests ---

test_bootstrap_creates_buckets() {
    "$BIN/hq-bootstrap" >/dev/null
    assert_dir "$T/code"
    assert_dir "$T/writing"
    assert_dir "$T/scratch"
    assert_dir "$T/archive/code"
    assert_dir "$T/archive/writing"
}

test_bootstrap_ignores_exempt_paths() {
    "$BIN/hq-bootstrap" >/dev/null
    # Exempt entries are not buckets: bootstrap must not conjure them.
    assert_no_dir "$T/vault"
    assert_no_dir "$T/dotclaude"
    assert_no_dir "$T/go"
    assert_no_dir "$T/chrome"
}

test_buckets_excludes_exempt() {
    source "$T/hq/lib/hq.sh"
    got="$(buckets | tr '\n' ' ')"
    assert_eq "$got" "code writing scratch " "buckets are only the [buckets.*] sections"
}

test_bootstrap_is_idempotent() {
    "$BIN/hq-bootstrap" >/dev/null
    mkdir -p "$T/code/keepme"
    "$BIN/hq-bootstrap" >/dev/null
    assert_dir "$T/code/keepme"
}

test_registry_parsing() {
    seed_registry
    source "$T/hq/lib/hq.sh"
    assert_eq "$(reg_field demo path)" "demo" "reg_field path"
    assert_eq "$(reg_field demo status)" "active" "reg_field status"
    assert_eq "$(reg_field other path)" "code/other" "second entry"
    assert_eq "$(reg_field demo missing)" "" "absent field is empty"
    assert_ok reg_has demo
    assert_fails reg_has nosuch
}

test_reg_set_field_updates_and_adds() {
    seed_registry
    source "$T/hq/lib/hq.sh"
    reg_set_field demo path code/demo
    assert_eq "$(reg_field demo path)" "code/demo" "updated existing field"
    assert_eq "$(reg_field other path)" "code/other" "neighbour untouched"
    reg_set_field demo vault projects/demo.md
    assert_eq "$(reg_field demo vault)" "projects/demo.md" "added missing field"
}

test_new_creates_and_registers() {
    "$BIN/hq-bootstrap" >/dev/null
    "$BIN/hq-new widget code >/dev/null" 2>/dev/null || "$BIN/hq-new" widget code >/dev/null
    assert_dir "$T/code/widget"
    assert_contains "$T/hq/REGISTRY.md" "## widget"
    assert_contains "$T/code/widget/STATUS.md" "widget"
}

test_new_refuses_duplicate() {
    "$BIN/hq-bootstrap" >/dev/null
    "$BIN/hq-new" widget code >/dev/null
    assert_fails "$BIN/hq-new" widget code
}

test_new_refuses_unknown_bucket() {
    "$BIN/hq-bootstrap" >/dev/null
    assert_fails "$BIN/hq-new" thing nonsense
}

test_move_relocates_and_updates_registry() {
    "$BIN/hq-bootstrap" >/dev/null
    seed_registry
    mkdir -p "$T/demo"; echo hi > "$T/demo/file.txt"
    "$BIN/hq-move" demo code/demo >/dev/null 2>&1
    assert_dir "$T/code/demo"
    assert_no_dir "$T/demo"
    assert_contains "$T/code/demo/file.txt" "hi"
    source "$T/hq/lib/hq.sh"
    assert_eq "$(reg_field demo path)" "code/demo" "registry updated"
}

test_move_repairs_path_symlink() {
    "$BIN/hq-bootstrap" >/dev/null
    seed_registry
    mkdir -p "$T/demo/tools" "$T/.local/bin"
    echo '#!/bin/sh' > "$T/demo/tools/thing"; chmod +x "$T/demo/tools/thing"
    ln -s "$T/demo/tools/thing" "$T/.local/bin/thing"
    "$BIN/hq-move" demo code/demo >/dev/null 2>&1
    assert_eq "$(readlink "$T/.local/bin/thing")" "$T/code/demo/tools/thing" "symlink repointed"
    assert_ok test -e "$T/.local/bin/thing"
}

test_move_refuses_existing_destination() {
    "$BIN/hq-bootstrap" >/dev/null
    seed_registry
    mkdir -p "$T/demo" "$T/code/demo"
    assert_fails "$BIN/hq-move" demo code/demo
    assert_dir "$T/demo"
}

test_move_refuses_unregistered() {
    "$BIN/hq-bootstrap" >/dev/null
    seed_registry
    mkdir -p "$T/ghost"
    assert_fails "$BIN/hq-move" ghost code/ghost
}

test_move_dry_run_changes_nothing() {
    "$BIN/hq-bootstrap" >/dev/null
    seed_registry
    mkdir -p "$T/demo"
    "$BIN/hq-move" demo code/demo --dry-run >/dev/null 2>&1
    assert_dir "$T/demo"
    assert_no_dir "$T/code/demo"
    source "$T/hq/lib/hq.sh"
    assert_eq "$(reg_field demo path)" "demo" "registry untouched by dry run"
}

test_move_dry_run_does_not_claim_success() {
    "$BIN/hq-bootstrap" >/dev/null
    seed_registry
    mkdir -p "$T/demo"
    out="$("$BIN/hq-move" demo code/demo --dry-run 2>&1)"
    if grep -q "is now at" <<<"$out"; then fail "dry run claimed the move happened"; else pass; fi
    if grep -q "dry run" <<<"$out"; then pass; else fail "dry run not announced"; fi
}

test_archive_moves_to_matching_bucket() {
    "$BIN/hq-bootstrap" >/dev/null
    seed_registry
    source "$T/hq/lib/hq.sh"
    reg_set_field demo path code/demo
    mkdir -p "$T/code/demo"
    "$BIN/hq-archive" demo >/dev/null 2>&1
    assert_dir "$T/archive/code/demo"
    assert_eq "$(reg_field demo status)" "archived" "status flipped"
}

test_cc_state_migrates_key_and_slug() {
    mkdir -p "$T/.claude/projects/-home-old-demo"
    echo '{"projects":{"/home/old/demo":{"trust":true},"/home/other":{}}}' > "$T/.claude.json"
    touch "$T/.claude/projects/-home-old-demo/session.jsonl"
    "$BIN/hq-migrate-cc-state" /home/old/demo /home/new/demo >/dev/null 2>&1
    assert_dir "$T/.claude/projects/-home-new-demo"
    assert_no_dir "$T/.claude/projects/-home-old-demo"
    assert_ok test -f "$T/.claude/projects/-home-new-demo/session.jsonl"
    assert_contains "$T/.claude.json" '/home/new/demo'
    if grep -q '"/home/old/demo"' "$T/.claude.json"; then fail "old key still present"; else pass; fi
    assert_contains "$T/.claude.json" '/home/other'
}

test_cc_state_handles_key_without_slug() {
    echo '{"projects":{"/home/old/demo":{}}}' > "$T/.claude.json"
    mkdir -p "$T/.claude/projects"
    assert_ok "$BIN/hq-migrate-cc-state" /home/old/demo /home/new/demo
    assert_contains "$T/.claude.json" '/home/new/demo'
}

test_cc_state_handles_slug_without_key() {
    echo '{"projects":{}}' > "$T/.claude.json"
    mkdir -p "$T/.claude/projects/-home-old-demo"
    assert_ok "$BIN/hq-migrate-cc-state" /home/old/demo /home/new/demo
    assert_dir "$T/.claude/projects/-home-new-demo"
}

test_audit_flags_unregistered_and_dead() {
    "$BIN/hq-bootstrap" >/dev/null
    seed_registry
    mkdir -p "$T/strayproject"          # unregistered
    # 'demo' and 'other' are registered but their dirs do not exist -> dead entries
    out="$("$BIN/hq-audit" 2>&1)" || true
    if grep -q "strayproject" <<<"$out"; then pass; else fail "audit missed unregistered dir"; fi
    if grep -q "demo" <<<"$out"; then pass; else fail "audit missed dead registry entry"; fi
    assert_fails "$BIN/hq-audit"        # non-zero when drift exists
}

test_audit_clean_when_consistent() {
    "$BIN/hq-bootstrap" >/dev/null
    cat > "$T/hq/REGISTRY.md" <<REG
# Registry

## demo
- path: code/demo
- status: active
- career: no
- summary: A demo.
REG
    mkdir -p "$T/code/demo"; touch "$T/code/demo/x"
    assert_ok "$BIN/hq-audit"
}

test_layout_exempt_parsing() {
    source "$T/hq/lib/hq.sh"
    if exempt_paths | grep -qx "vault"; then pass; else fail "vault not parsed as exempt"; fi
    if exempt_paths | grep -qx "dotclaude"; then pass; else fail "dotclaude not parsed as exempt"; fi
    assert_contains <(exempt_reason dotclaude) "symlink"
}

# Claude Code slugs a path by replacing every character outside [A-Za-z0-9-],
# not just '/'. So ~/my_project maps to -home-<user>-my-project, and a dotted
# directory like ~/.config to -home-<user>--config (the separator doubles).
# Getting this wrong makes the migration print a reassuring "skipping".
test_cc_state_slug_collapses_underscores_and_dots() {
    source "$T/hq/lib/hq.sh"
    assert_eq "$(cc_slug /home/old/my_project)" "-home-old-my-project" "underscore"
    assert_eq "$(cc_slug /home/old/.config)" "-home-old--config" "leading dot"
    assert_eq "$(cc_slug /home/old/WebApp)" "-home-old-WebApp" "case preserved"
}

test_cc_state_migrates_underscore_slug() {
    mkdir -p "$T/.claude/projects/-home-old-my-project"
    echo '{"projects":{"/home/old/my_project":{}}}' > "$T/.claude.json"
    touch "$T/.claude/projects/-home-old-my-project/s.jsonl"
    "$BIN/hq-migrate-cc-state" /home/old/my_project /home/new/my_project >/dev/null 2>&1
    assert_dir "$T/.claude/projects/-home-new-my-project"
    assert_no_dir "$T/.claude/projects/-home-old-my-project"
    assert_ok test -f "$T/.claude/projects/-home-new-my-project/s.jsonl"
}

# A project with nested projects inside it (loop-engineering has four) keys each
# one separately. Renaming only the parent abandons the children on dead paths.
test_cc_state_migrates_nested_keys() {
    mkdir -p "$T/.claude/projects/-home-old-demo" "$T/.claude/projects/-home-old-demo-sub"
    cat > "$T/.claude.json" <<'JSON'
{"projects":{"/home/old/demo":{"a":1},"/home/old/demo/sub":{"b":2},
             "/home/old/demoted":{"c":3},"/home/other":{}}}
JSON
    "$BIN/hq-migrate-cc-state" /home/old/demo /home/new/demo >/dev/null 2>&1
    assert_contains "$T/.claude.json" '/home/new/demo/sub'
    assert_dir "$T/.claude/projects/-home-new-demo-sub"
    if grep -q '"/home/old/demo/sub"' "$T/.claude.json"; then fail "nested key left behind"; else pass; fi
    # A sibling sharing a name prefix is a different project, not a child.
    assert_contains "$T/.claude.json" '/home/old/demoted'
}

# Memory files carry absolute project paths in their prose. Left alone they
# describe a directory that no longer exists, which is worse than a dead link:
# a model reads them as fact.
test_cc_state_rewrites_memory_paths() {
    mkdir -p "$T/.claude/projects/-home-old-demo/memory"
    echo '{"projects":{}}' > "$T/.claude.json"
    printf 'Build it in /home/old/demo/src, see /home/old/demo/PLAN.md\n' \
        > "$T/.claude/projects/-home-old-demo/memory/notes.md"
    "$BIN/hq-migrate-cc-state" /home/old/demo /home/new/demo >/dev/null 2>&1
    m="$T/.claude/projects/-home-new-demo/memory/notes.md"
    assert_contains "$m" "/home/new/demo/src"
    assert_contains "$m" "/home/new/demo/PLAN.md"
    if grep -q '/home/old/demo' "$m"; then fail "old path left in memory file"; else pass; fi
}

# The deferral is the guaranteed path when a session is live, so it must leave a
# record on disk. A warning on stderr is a warning in scrollback.
test_move_queues_deferred_migration() {
    "$BIN/hq-bootstrap" >/dev/null
    seed_registry
    mkdir -p "$T/demo"
    HQ_ASSUME_CLAUDE_RUNNING=1 "$BIN/hq-move" demo code/demo >/dev/null 2>&1
    q="$T/hq/pending-cc-migration.tsv"
    assert_ok test -f "$q"
    assert_contains "$q" "$T/demo	$T/code/demo"
    assert_eq "$(wc -l < "$q")" "1" "one line per deferred move"
    # Re-recording the same pair must not grow the queue.
    source "$T/hq/lib/hq.sh"
    cc_queue_append "$T/demo" "$T/code/demo"
    assert_eq "$(wc -l < "$q")" "1" "queue is deduped"
}

test_move_does_not_queue_when_migration_runs() {
    "$BIN/hq-bootstrap" >/dev/null
    seed_registry
    mkdir -p "$T/demo"
    echo '{"projects":{}}' > "$T/.claude.json"
    "$BIN/hq-move" demo code/demo >/dev/null 2>&1
    assert_no_dir "$T/hq/pending-cc-migration.tsv"
}

# hq-migrate-cc-state's premise is that <old> has already moved away. If <old>
# exists again it belongs to a reused path, so migrating would move that
# project's key and transcripts onto the old destination. It must skip loudly,
# not clobber, and not abort a wholesale replay of the rest of the queue.
test_cc_state_skips_reused_old_path() {
    mkdir -p "$T/reused"
    printf '{"projects":{"%s/reused":{"marker":true}}}\n' "$T" > "$T/.claude.json"
    slug="$T/.claude/projects/$(printf '%s' "$T/reused" | tr -c 'a-zA-Z0-9' '-')"
    mkdir -p "$slug"
    out="$("$BIN/hq-migrate-cc-state" "$T/reused" "$T/code/reused" 2>&1)"
    assert_eq "$?" "0" "a reused old path is skipped, not fatal"
    if grep -q "skipping to avoid clobbering" <<<"$out"; then pass; else fail "no reuse warning"; fi
    assert_contains "$T/.claude.json" "$T/reused"
    if grep -qF "$T/code/reused" "$T/.claude.json"; then fail "reused key was migrated"; else pass; fi
    assert_dir "$slug"
}

# A clean pass leaves nothing pending, so the runner removes the queue instead
# of letting applied lines accumulate. A --dry-run must leave it in place.
test_pending_runner_drains_applied_queue() {
    echo '{"projects":{}}' > "$T/.claude.json"
    q="$T/hq/pending-cc-migration.tsv"
    printf '%s/gone-old\t%s/gone-new\n' "$T" "$T" > "$q"
    "$T/hq/pending-cc-migration.sh" --dry-run >/dev/null 2>&1
    assert_ok test -f "$q"
    "$T/hq/pending-cc-migration.sh" >/dev/null 2>&1
    assert_no_dir "$q"
}

# The registry must describe where the directory actually is. If a repair step
# downstream of the mv dies, a registry written last is left lying.
test_move_updates_registry_even_when_a_repair_fails() {
    "$BIN/hq-bootstrap" >/dev/null
    seed_registry
    mkdir -p "$T/demo"
    # Force hq-migrate-cc-state to die: source slug present and destination slug
    # already taken, which it refuses to overwrite. Seed both spellings so the
    # test does not silently stop biting when the slug transform changes.
    for p in "$T/demo" "$T/code/demo"; do
        mkdir -p "$T/.claude/projects/$(printf '%s' "$p" | tr '/' '-')"
        mkdir -p "$T/.claude/projects/$(printf '%s' "$p" | tr -c 'a-zA-Z0-9' '-')"
    done
    echo '{"projects":{}}' > "$T/.claude.json"
    "$BIN/hq-move" demo code/demo >/dev/null 2>&1
    assert_dir "$T/code/demo"
    source "$T/hq/lib/hq.sh"
    assert_eq "$(reg_field demo path)" "code/demo" "registry tracks the move despite the failure"
}

test_reg_set_field_preserves_mode() {
    seed_registry
    chmod 644 "$T/hq/REGISTRY.md"
    source "$T/hq/lib/hq.sh"
    reg_set_field demo path code/demo
    assert_eq "$(stat -c %a "$T/hq/REGISTRY.md")" "644" "mode survives the rewrite"
}

# pip writes a .pth with no trailing newline, so a bare `read` loop drops the
# only line in the file and the warning never fires.
test_move_warns_about_editable_pth_without_trailing_newline() {
    "$BIN/hq-bootstrap" >/dev/null
    seed_registry
    mkdir -p "$T/demo/src" "$T/.local/lib/python3.12/site-packages"
    printf '%s' "$T/demo/src" > "$T/.local/lib/python3.12/site-packages/_editable_impl_demo.pth"
    out="$("$BIN/hq-move" demo code/demo 2>&1)"
    if grep -q "editable install points at the old path" <<<"$out"; then pass
    else fail "no-trailing-newline .pth not reported"; fi
}

test_move_ignores_pth_for_a_name_prefixed_sibling() {
    "$BIN/hq-bootstrap" >/dev/null
    seed_registry
    mkdir -p "$T/demo" "$T/.local/lib/python3.12/site-packages"
    echo "$T/demoted/src" > "$T/.local/lib/python3.12/site-packages/_editable_impl_other.pth"
    out="$("$BIN/hq-move" demo code/demo 2>&1)"
    if grep -q "editable install" <<<"$out"; then fail "flagged an unrelated project"; else pass; fi
}

# A symlink whose target is the project root itself, with no trailing path.
test_move_relinks_symlink_to_project_root() {
    "$BIN/hq-bootstrap" >/dev/null
    seed_registry
    mkdir -p "$T/demo" "$T/.local/bin"
    ln -s "$T/demo" "$T/.local/bin/demoroot"
    "$BIN/hq-move" demo code/demo >/dev/null 2>&1
    assert_eq "$(readlink "$T/.local/bin/demoroot")" "$T/code/demo" "root symlink repointed"
    assert_ok test -e "$T/.local/bin/demoroot"
}

# The one surviving venv in this batch sits at depth 4.
test_move_warns_about_nested_venv() {
    "$BIN/hq-bootstrap" >/dev/null
    seed_registry
    mkdir -p "$T/demo/proto/bench/.venv"
    touch "$T/demo/proto/bench/.venv/pyvenv.cfg"
    out="$("$BIN/hq-move" demo code/demo 2>&1)"
    if grep -q "stale venv" <<<"$out"; then pass; else fail "deep venv not reported"; fi
}

# A dry run that hides the warnings is worse than no dry run: it reports clean.
test_move_dry_run_warns_about_venv() {
    "$BIN/hq-bootstrap" >/dev/null
    seed_registry
    mkdir -p "$T/demo/.venv"; touch "$T/demo/.venv/pyvenv.cfg"
    out="$("$BIN/hq-move" demo code/demo --dry-run 2>&1)"
    if grep -q "stale venv" <<<"$out"; then pass; else fail "dry run hid the venv warning"; fi
    assert_dir "$T/demo"
}

test_move_dry_run_does_not_claim_a_relink() {
    "$BIN/hq-bootstrap" >/dev/null
    seed_registry
    mkdir -p "$T/demo/tools" "$T/.local/bin"
    touch "$T/demo/tools/thing"
    ln -s "$T/demo/tools/thing" "$T/.local/bin/thing"
    out="$("$BIN/hq-move" demo code/demo --dry-run 2>&1)"
    if grep -q "relinked" <<<"$out"; then fail "dry run claimed a relink happened"; else pass; fi
    assert_eq "$(readlink "$T/.local/bin/thing")" "$T/demo/tools/thing" "symlink untouched"
}

# find | sort | head under `set -o pipefail` dies with SIGPIPE once sort's
# output exceeds the 64K pipe buffer. 4000 files is enough to reproduce it.
test_audit_survives_a_large_tree() {
    "$BIN/hq-bootstrap" >/dev/null
    cat > "$T/hq/REGISTRY.md" <<REG
# Registry

## demo
- path: code/demo
- status: active
- career: no
- summary: A demo.
REG
    mkdir -p "$T/code/demo"
    for i in $(seq 1 4000); do : > "$T/code/demo/f$i"; done
    rc=0; "$BIN/hq-audit" >/dev/null 2>&1 || rc=$?
    if (( rc == 141 )); then fail "hq-audit died with SIGPIPE on a large tree"; else pass; fi
    assert_eq "$rc" "0" "clean tree audits clean"
}

test_newest_mtime_reports_the_maximum() {
    source "$T/hq/lib/hq.sh"
    mkdir -p "$T/tree/a"
    touch -d '2020-01-01' "$T/tree/old"
    touch -d '2024-06-01' "$T/tree/a/new"
    touch -d '2022-01-01' "$T/tree/mid"
    got="$(newest_mtime "$T/tree")"
    want="$(date -d '2024-06-01' +%s)"
    assert_eq "${got%.*}" "$want" "picks the newest file"
    assert_eq "$(newest_mtime "$T/nonexistent")" "" "missing tree yields nothing"
}

# --- unregistered directories inside a bucket ---------------------------------

# The scan used to look only at $HOME/*/, so a clone dropped into a bucket --
# the normal way a project arrives -- was invisible to it.
test_audit_flags_unregistered_dir_inside_a_bucket() {
    "$BIN/hq-bootstrap" >/dev/null
    cat > "$T/hq/REGISTRY.md" <<REG
# Registry

## demo
- path: code/demo
- status: active
- career: no
- summary: A demo.
REG
    mkdir -p "$T/code/demo" "$T/code/some-clone"
    out="$("$BIN/hq-audit" 2>&1)" || true
    if grep -q "code/some-clone" <<<"$out"; then pass; else fail "missed unregistered dir inside a bucket"; fi
    if grep -q "code/demo" <<<"$out"; then fail "flagged a registered dir"; else pass; fi
    assert_fails "$BIN/hq-audit"
}

# Entries are keyed by name, directories by path, and for real entries the two
# differ: essay lives at archive/writing/history-paper. Matching on
# basename would flag every such entry the day it shipped.
test_audit_matches_by_path_not_basename() {
    "$BIN/hq-bootstrap" >/dev/null
    cat > "$T/hq/REGISTRY.md" <<REG
# Registry

## essay
- path: archive/writing/history-paper
- status: archived
- career: no
- summary: Name and directory deliberately differ.
REG
    mkdir -p "$T/archive/writing/history-paper"
    assert_ok "$BIN/hq-audit"
}

test_audit_respects_exempt_paths_inside_a_bucket() {
    "$BIN/hq-bootstrap" >/dev/null
    printf '# Registry\n' > "$T/hq/REGISTRY.md"
    mkdir -p "$T/writing/library"
    assert_ok "$BIN/hq-audit"
}

# layout.toml declares scratch throwaway, so demanding paperwork there is noise.
test_audit_ignores_scratch_contents() {
    "$BIN/hq-bootstrap" >/dev/null
    printf '# Registry\n' > "$T/hq/REGISTRY.md"
    mkdir -p "$T/scratch/some-experiment"
    assert_ok "$BIN/hq-audit"
}

# loop-engineering holds 4 nested repos and cs3157 holds 18. Descending past one
# level turns the audit into output nobody reads.
test_audit_does_not_descend_past_one_level() {
    "$BIN/hq-bootstrap" >/dev/null
    cat > "$T/hq/REGISTRY.md" <<REG
# Registry

## demo
- path: code/demo
- status: active
- career: no
- summary: A demo.
REG
    mkdir -p "$T/code/demo/nested-repo"
    assert_ok "$BIN/hq-audit"
}

# --- hq-register --------------------------------------------------------------

test_register_adopts_an_existing_directory() {
    "$BIN/hq-bootstrap" >/dev/null
    printf '# Registry\n' > "$T/hq/REGISTRY.md"
    mkdir -p "$T/code/cloned"; : > "$T/code/cloned/README.md"
    "$BIN/hq-register" cloned code/cloned "A clone." >/dev/null
    assert_contains "$T/hq/REGISTRY.md" "## cloned"
    source "$T/hq/lib/hq.sh"
    assert_eq "$(reg_field cloned path)" "code/cloned" "path recorded"
    assert_eq "$(reg_field cloned summary)" "A clone." "summary recorded"
    assert_ok "$BIN/hq-audit"       # the point of the command: drift is cleared
}

test_register_detects_docs() {
    "$BIN/hq-bootstrap" >/dev/null
    printf '# Registry\n' > "$T/hq/REGISTRY.md"
    mkdir -p "$T/code/withdocs"
    : > "$T/code/withdocs/README.md"; : > "$T/code/withdocs/STATUS.md"
    "$BIN/hq-register" withdocs code/withdocs >/dev/null
    source "$T/hq/lib/hq.sh"
    assert_eq "$(reg_field withdocs docs)" "STATUS.md, README.md" "docs detected, in probe order"
}

test_register_omits_docs_when_there_are_none() {
    "$BIN/hq-bootstrap" >/dev/null
    printf '# Registry\n' > "$T/hq/REGISTRY.md"
    mkdir -p "$T/code/bare"
    "$BIN/hq-register" bare code/bare >/dev/null
    source "$T/hq/lib/hq.sh"
    assert_eq "$(reg_field bare docs)" "" "no docs field when the tree has none"
}

test_register_refuses_duplicate_name() {
    "$BIN/hq-bootstrap" >/dev/null
    seed_registry
    mkdir -p "$T/code/whatever"
    assert_fails "$BIN/hq-register" demo code/whatever
}

# hq-new demands the directory not exist; hq-register demands that it does.
test_register_refuses_a_missing_directory() {
    "$BIN/hq-bootstrap" >/dev/null
    printf '# Registry\n' > "$T/hq/REGISTRY.md"
    assert_fails "$BIN/hq-register" ghost code/ghost
}

# One directory with two entries is how the registry starts lying.
test_register_refuses_a_path_already_registered() {
    "$BIN/hq-bootstrap" >/dev/null
    seed_registry
    mkdir -p "$T/code/other"
    assert_fails "$BIN/hq-register" second-name code/other
}

# Paths are $HOME-relative so the registry survives $HOME moving.
test_register_refuses_an_absolute_path() {
    "$BIN/hq-bootstrap" >/dev/null
    printf '# Registry\n' > "$T/hq/REGISTRY.md"
    mkdir -p "$T/code/abs"
    assert_fails "$BIN/hq-register" abs "$T/code/abs"
}

test_register_refuses_a_traversing_path() {
    "$BIN/hq-bootstrap" >/dev/null
    printf '# Registry\n' > "$T/hq/REGISTRY.md"
    mkdir -p "$T/code/trav"
    assert_fails "$BIN/hq-register" trav code/../code/trav
}

# Cloning to the wrong place and then hq-move'ing is a legitimate two-step, so
# this warns instead of refusing, and the audit reports the interim state.
test_register_allows_a_top_level_path() {
    "$BIN/hq-bootstrap" >/dev/null
    printf '# Registry\n' > "$T/hq/REGISTRY.md"
    mkdir -p "$T/stray"
    assert_ok "$BIN/hq-register" stray stray
    out="$("$BIN/hq-audit" 2>&1)" || true
    if grep -q "still at top level" <<<"$out"; then pass; else fail "audit should report a registered top-level dir"; fi
}

# career: is a forcing function. Registering must not answer it for you.
test_register_leaves_the_career_decision_open() {
    "$BIN/hq-bootstrap" >/dev/null
    printf '# Registry\n' > "$T/hq/REGISTRY.md"
    mkdir -p "$T/code/undecided" "$T/vault/projects"
    "$BIN/hq-register" undecided code/undecided >/dev/null
    out="$("$BIN/hq-audit" 2>&1)" || true
    if grep -q "not tagged 'career: no'" <<<"$out"; then pass; else fail "audit should ask for the career decision"; fi
}

# --- layout and registry helpers ----------------------------------------------

test_bucket_archive_and_registers_helpers() {
    source "$T/hq/lib/hq.sh"
    assert_eq "$(bucket_archive code)" "archive/code" "code archives to archive/code"
    assert_eq "$(bucket_archive writing)" "archive/writing" "writing archives to archive/writing"
    assert_eq "$(bucket_archive scratch)" "" "scratch has no archive"
    if bucket_registers code;    then pass; else fail "code should require registration"; fi
    if bucket_registers scratch; then fail "scratch should not require registration"; else pass; fi
}

test_reg_paths_lists_every_path() {
    "$BIN/hq-bootstrap" >/dev/null
    seed_registry
    source "$T/hq/lib/hq.sh"
    assert_eq "$(reg_paths | tr '\n' ' ')" "demo code/other " "every registered path"
}

# --- cross-home flows ---------------------------------------------------------

# A flow resolves its target to a project directory and its source to an MCP
# server; hq-flow prints the resolved target path in its dispatch block.
test_flow_resolves_a_good_flow() {
    seed_registry; seed_sources; seed_flows
    mkdir -p "$T/demo"
    source "$T/hq/lib/hq.sh"
    assert_eq "$(flow_resolve_target demo)" "$T/demo" "target -> abs path"
    assert_eq "$(flow_resolve_source gw-demo)" "$(printf 'mcp\tgw-demo')" "source -> mcp server"
    assert_ok "$BIN/hq-flow" good-flow
    out="$("$BIN/hq-flow" good-flow 2>&1)"
    if grep -qF "$T/demo" <<<"$out"; then pass; else fail "hq-flow did not print the resolved target path"; fi
}

# A target that is neither a live project nor 'vault' is a dead edge.
test_flow_rejects_a_dead_target() {
    seed_registry; seed_sources; seed_flows
    mkdir -p "$T/demo"
    source "$T/hq/lib/hq.sh"
    assert_fails flow_resolve_target nosuch
    assert_fails "$BIN/hq-flow" dead-target
}

# A source that is not a project, a known SOURCES server, or an existing path is dead.
test_flow_rejects_a_dead_source() {
    seed_registry; seed_sources; seed_flows
    mkdir -p "$T/demo"
    source "$T/hq/lib/hq.sh"
    assert_fails flow_resolve_source gw-ghost
    assert_fails "$BIN/hq-flow" dead-source
}

# 'vault' is an exempt path, not a registry entry, yet must resolve both ways.
test_flow_vault_token_resolves_without_a_registry_entry() {
    seed_registry; seed_sources
    mkdir -p "$T/vault"
    source "$T/hq/lib/hq.sh"
    assert_eq "$(flow_resolve_target vault)" "$T/vault" "vault target -> ~/vault"
    assert_eq "$(flow_resolve_source vault)" "$(printf 'path\t%s' "$T/vault")" "vault source -> path"
}

# The audit reports a dead edge on either side and exits non-zero for it.
test_audit_flags_a_dead_flow_edge() {
    "$BIN/hq-bootstrap" >/dev/null
    seed_registry; seed_sources; seed_flows
    mkdir -p "$T/demo" "$T/code/other"
    out="$("$BIN/hq-audit" 2>&1)" || true
    if grep -q "dead-target" <<<"$out"; then pass; else fail "audit missed the dead target edge"; fi
    if grep -q "dead-source" <<<"$out"; then pass; else fail "audit missed the dead source edge"; fi
    assert_fails "$BIN/hq-audit"
}

# No FLOWS.md means the audit's flows section is skipped, not failed.
test_audit_clean_without_a_flows_file() {
    "$BIN/hq-bootstrap" >/dev/null
    cat > "$T/hq/REGISTRY.md" <<REG
# Registry

## demo
- path: code/demo
- status: active
- career: no
- summary: A demo.
REG
    mkdir -p "$T/code/demo"; touch "$T/code/demo/x"
    assert_ok "$BIN/hq-audit"
}

# --- vault cross-check skip marker ------------------------------------------

# A remote-only repo (no local checkout) has no registry entry; the vault file
# marks that with `mirrored: false`, and the cross-check must skip it, not warn.
test_audit_skips_a_remote_only_vault_file() {
    "$BIN/hq-bootstrap" >/dev/null
    cat > "$T/hq/REGISTRY.md" <<REG
# Registry

## demo
- path: code/demo
- status: active
- career: no
- summary: A demo.
REG
    mkdir -p "$T/code/demo"; touch "$T/code/demo/x"
    mkdir -p "$T/vault/projects"
    printf -- '---\nrepo: ghost\nmirrored: false\n---\n' > "$T/vault/projects/ghost.md"
    assert_ok "$BIN/hq-audit"
}

# The same file without the marker is a genuine orphan: no registry entry and
# nothing saying it is remote-only. That is drift, and `external` is not the
# marker (it is the ownership axis), so a file carrying only `external` still warns.
test_audit_flags_a_registryless_vault_file_without_the_marker() {
    "$BIN/hq-bootstrap" >/dev/null
    cat > "$T/hq/REGISTRY.md" <<REG
# Registry

## demo
- path: code/demo
- status: active
- career: no
- summary: A demo.
REG
    mkdir -p "$T/code/demo"; touch "$T/code/demo/x"
    mkdir -p "$T/vault/projects"
    printf -- '---\nrepo: orphan\nexternal: true\n---\n' > "$T/vault/projects/orphan.md"
    out="$("$BIN/hq-audit" 2>&1)" || true
    if grep -q "orphan" <<<"$out"; then pass; else fail "audit missed a registryless vault file with no mirrored marker"; fi
    assert_fails "$BIN/hq-audit"
}

# The pre-publish gate must pass against the REAL repository (not the sandbox):
# no private strings in the publishable file set, every private map gitignored,
# every example twin present. This guards against a future edit reintroducing a
# leak before the repo is made public.
test_publish_check_passes_on_the_real_repo() {
    assert_ok env HQ_ROOT="$REPO" "$REPO/bin/hq-publish-check"
}

# --- private state overlay ----------------------------------------------------

# The overlay is a second git dir over the same work tree, holding only the
# files the code repo ignores. These run against the sandbox copy, which carries
# the real repo's .git, so `git -C "$T/hq"` is the code repo.
state_git() { git --git-dir="$T/hq/.state.git" --work-tree="$T/hq" "$@"; }

test_state_add_tracks_an_ignored_private_file() {
    "$BIN/hq-bootstrap" >/dev/null
    assert_ok "$BIN/hq-state" init
    assert_ok "$BIN/hq-state" add REGISTRY.md
    assert_eq "$(state_git ls-files)" "REGISTRY.md" "overlay tracked set"
}

test_state_add_refuses_a_code_file() {
    "$BIN/hq-state" init >/dev/null
    assert_fails "$BIN/hq-state" add README.md
    assert_eq "$(state_git ls-files)" "" "a refused add must track nothing"
}

test_state_add_refuses_a_publishable_untracked_file() {
    "$BIN/hq-state" init >/dev/null
    echo scratch > "$T/hq/notes.txt"
    assert_fails "$BIN/hq-state" add notes.txt
}

test_state_passes_other_commands_to_git() {
    "$BIN/hq-bootstrap" >/dev/null
    "$BIN/hq-state" init >/dev/null
    "$BIN/hq-state" add REGISTRY.md >/dev/null
    assert_ok "$BIN/hq-state" commit -qm "track registry"
    assert_eq "$("$BIN/hq-state" log --format=%s)" "track registry" "passthrough commit/log"
}

# sync is the session-end snapshot: it commits edits to tracked files and picks
# up new private files inside directories the overlay already tracks (e.g. a new
# memory note), but never starts tracking a file in a fresh location.
test_state_sync_commits_edits_and_new_files_in_tracked_dirs() {
    "$BIN/hq-bootstrap" >/dev/null
    rm -rf "$T/hq/docs/local"; mkdir -p "$T/hq/docs/local"; echo one > "$T/hq/docs/local/a.md"
    "$BIN/hq-state" init >/dev/null
    "$BIN/hq-state" add REGISTRY.md docs/local/a.md >/dev/null
    "$BIN/hq-state" commit -qm base
    echo "edit" >> "$T/hq/REGISTRY.md"
    echo two > "$T/hq/docs/local/b.md"
    assert_ok "$BIN/hq-state" sync "snap"
    assert_eq "$(state_git ls-files | sort | tr '\n' ' ')" "REGISTRY.md docs/local/a.md docs/local/b.md " "tracked after sync"
    assert_eq "$(state_git status --porcelain)" "" "clean after sync"
    assert_contains <(state_git log -1 --format=%s) "snap"
}

test_state_sync_handles_spaces_in_paths() {
    "$BIN/hq-bootstrap" >/dev/null
    rm -rf "$T/hq/docs/local"; mkdir -p "$T/hq/docs/local/my notes"; echo a > "$T/hq/docs/local/my notes/a b.md"; echo k > "$T/hq/docs/local/合気道.md"
    "$BIN/hq-state" init >/dev/null
    "$BIN/hq-state" add "docs/local/my notes/a b.md" "docs/local/合気道.md" >/dev/null
    "$BIN/hq-state" commit -qm base
    echo c > "$T/hq/docs/local/my notes/c d.md"; echo k2 > "$T/hq/docs/local/道場.md"
    assert_ok "$BIN/hq-state" sync
    assert_eq "$(state_git -c core.quotePath=false ls-files | LC_ALL=C sort | tr '\n' '|')" "docs/local/my notes/a b.md|docs/local/my notes/c d.md|docs/local/合気道.md|docs/local/道場.md|" "spaced and non-ASCII paths"
}

test_state_sync_ignores_new_files_outside_tracked_dirs() {
    "$BIN/hq-bootstrap" >/dev/null
    "$BIN/hq-state" init >/dev/null
    "$BIN/hq-state" add REGISTRY.md >/dev/null
    "$BIN/hq-state" commit -qm base
    rm -rf "$T/hq/docs/local"; mkdir -p "$T/hq/docs/local"; echo x > "$T/hq/docs/local/new.md"
    assert_ok "$BIN/hq-state" sync
    assert_eq "$(state_git ls-files)" "REGISTRY.md" "no new location adopted"
}

test_state_sync_is_a_noop_when_clean() {
    "$BIN/hq-bootstrap" >/dev/null
    "$BIN/hq-state" init >/dev/null
    "$BIN/hq-state" add REGISTRY.md >/dev/null
    "$BIN/hq-state" commit -qm base
    assert_ok "$BIN/hq-state" sync
    assert_eq "$(state_git rev-list --count HEAD)" "1" "no empty commit"
}

test_state_init_refuses_an_existing_overlay() {
    "$BIN/hq-state" init >/dev/null
    assert_fails "$BIN/hq-state" init
}

# A restore lands on a fresh clone that install.sh may already have seeded, so
# it must never overwrite a file on disk: missing files appear, existing ones
# stay and show up as a diff to reconcile.
test_state_restore_populates_without_overwriting() {
    "$BIN/hq-bootstrap" >/dev/null
    seed_sources
    "$BIN/hq-state" init >/dev/null
    "$BIN/hq-state" add REGISTRY.md SOURCES.md >/dev/null
    "$BIN/hq-state" commit -qm "state"
    git clone -q --bare "$T/hq/.state.git" "$T/remote.git"
    rm -rf "$T/hq/.state.git" "$T/hq/SOURCES.md"
    echo "local edit" >> "$T/hq/REGISTRY.md"
    assert_ok "$BIN/hq-state" restore "$T/remote.git"
    assert_contains "$T/hq/SOURCES.md" "gmail-demo"
    assert_contains "$T/hq/REGISTRY.md" "local edit"
    assert_eq "$(state_git diff --name-only)" "REGISTRY.md" "pre-existing file shows as a diff"
    assert_eq "$(state_git config --get remote.origin.url)" "$T/remote.git" "origin set"
}

test_state_restore_refuses_an_existing_overlay() {
    "$BIN/hq-state" init >/dev/null
    assert_fails "$BIN/hq-state" restore "$T/nowhere.git"
}

# The two layers must never cross. The overlay is written to with raw git here
# to simulate a mistake the wrapper would have refused.
test_publish_check_passes_with_a_disjoint_overlay() {
    "$BIN/hq-bootstrap" >/dev/null
    "$BIN/hq-state" init >/dev/null
    "$BIN/hq-state" add REGISTRY.md >/dev/null
    assert_ok "$BIN/hq-publish-check"
}

test_publish_check_fails_on_a_file_tracked_by_both_layers() {
    "$BIN/hq-state" init >/dev/null
    state_git add -f README.md
    assert_fails "$BIN/hq-publish-check"
}

test_publish_check_fails_on_a_publishable_file_in_the_overlay() {
    "$BIN/hq-state" init >/dev/null
    echo scratch > "$T/hq/notes.txt"
    state_git add -f notes.txt
    rm "$T/hq/notes.txt"     # isolate the overlay check from the tree scan
    assert_fails "$BIN/hq-publish-check"
}

test_publish_check_requires_the_overlay_dir_ignored() {
    grep -v '^\.state\.git$' "$T/hq/.gitignore" > "$T/gi" && mv "$T/gi" "$T/hq/.gitignore"
    assert_fails "$BIN/hq-publish-check"
}

# --- pre-push gate -------------------------------------------------------------

# commit_on <parent|-> <message>: a commit of HEAD's tree, printed by sha.
commit_on() {
    local parent=()
    [[ "$1" != "-" ]] && parent=(-p "$1")
    git -C "$T/hq" commit-tree "${parent[@]}" -m "$2" "HEAD^{tree}"
}

pre_push() { printf '%s\n' "$1" | (cd "$T/hq" && hooks/pre-push origin url); }

test_pre_push_allows_a_clean_commit() {
    local base new
    base="$(git -C "$T/hq" rev-parse HEAD)"
    new="$(commit_on "$base" "an ordinary change")"
    assert_ok pre_push "refs/heads/master $new refs/heads/master $base"
}

test_pre_push_blocks_a_denylisted_commit_message() {
    local base new
    echo 'zanzibarproj' > "$T/hq/.publish-denylist"
    base="$(git -C "$T/hq" rev-parse HEAD)"
    new="$(commit_on "$base" "wire up zanzibarproj")"
    assert_fails pre_push "refs/heads/master $new refs/heads/master $base"
}

test_pre_push_blocks_a_denylisted_added_line() {
    local base new
    echo 'zanzibarproj' > "$T/hq/.publish-denylist"
    base="$(git -C "$T/hq" rev-parse HEAD)"
    echo "see zanzibarproj" > "$T/hq/leak.txt"
    git -C "$T/hq" add leak.txt && git -C "$T/hq" commit -qm "innocent message"
    new="$(git -C "$T/hq" rev-parse HEAD)"
    git -C "$T/hq" rm -q leak.txt && git -C "$T/hq" commit -qm "cleanup"
    assert_fails pre_push "refs/heads/master $new refs/heads/master $base"
}

test_pre_push_blocks_history_shared_with_private_history() {
    local root child
    root="$(commit_on - "old private past")"
    git -C "$T/hq" tag -f private-history "$root" >/dev/null
    child="$(commit_on "$root" "built on it")"
    assert_fails pre_push "refs/heads/leak $child refs/heads/leak 0000000000000000000000000000000000000000"
    assert_fails pre_push "refs/tags/private-history $root refs/tags/private-history 0000000000000000000000000000000000000000"
}

test_pre_push_blocks_when_the_tree_check_fails() {
    local base new
    base="$(git -C "$T/hq" rev-parse HEAD)"
    new="$(commit_on "$base" "an ordinary change")"
    grep -v '^REGISTRY\.md$' "$T/hq/.gitignore" > "$T/gi" && mv "$T/gi" "$T/hq/.gitignore"
    assert_fails pre_push "refs/heads/master $new refs/heads/master $base"
}

test_pre_push_ignores_a_branch_deletion() {
    assert_ok pre_push "(delete) 0000000000000000000000000000000000000000 refs/heads/gone $(git -C "$T/hq" rev-parse HEAD)"
}

test_install_wires_the_pre_push_hook_idempotently() {
    "$T/hq/install.sh" >/dev/null
    "$T/hq/install.sh" >/dev/null
    assert_eq "$(git -C "$T/hq" config --get-all core.hooksPath)" "hooks" "hooksPath set once"
}

# --- runner ---

tests=$(declare -F | awk '{print $3}' | grep '^test_' | sort)
[[ $# -gt 0 ]] && tests="$*"

for t in $tests; do
    printf '%s\n' "$t"
    before="$(count fail)"
    setup
    # Subshell: a test that sources lib/hq.sh picks up its `set -e`, and an
    # abort there must fail one test, not kill the run.
    ( "$t" ) || fail "$t aborted (exit $?)"
    teardown
    [[ "$(count fail)" -eq "$before" ]] && printf '  \033[32m✓\033[0m\n' || FAILED+=("$t")
done

printf '\n%d passed, %d failed\n' "$(count pass)" "$(count fail)"
if (( $(count fail) )); then printf 'failed: %s\n' "${FAILED[*]}"; exit 1; fi
