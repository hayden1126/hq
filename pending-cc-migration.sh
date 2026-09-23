#!/usr/bin/env bash
# Replay the deferred Claude Code state migrations recorded in
# pending-cc-migration.tsv (one "<old>\t<new>" pair per line).
#
# hq-move cannot do this step while Claude Code is running: a live session
# rewrites ~/.claude.json from memory and would clobber the edit. So it queues
# the pair instead of printing a warning nobody will scroll back to.
#
#   RUN THIS FROM A PLAIN SHELL WITH NO CLAUDE CODE SESSION OPEN.
#
# Safe to re-run: an applied migration no-ops (nothing at the old path), and
# hq-migrate-cc-state skips any line whose old path has been reused rather than
# clobber it. A clean pass leaves nothing pending, so the queue is removed at
# the end — it is not a durable record. Pass --dry-run to see what it would
# touch (the queue is then left in place).
set -euo pipefail

HQ_ROOT="$(cd "$(dirname "$0")" && pwd)"
QUEUE="$HQ_ROOT/pending-cc-migration.tsv"
M="$HQ_ROOT/bin/hq-migrate-cc-state"

[[ -f "$QUEUE" ]] || { echo "nothing queued: $QUEUE does not exist"; exit 0; }

# A dry run must touch nothing, the queue included.
dry=0
for a in "$@"; do [[ "$a" == "--dry-run" ]] && dry=1; done

n=0
while IFS=$'\t' read -r old new; do
    [[ -n "${old:-}" && -n "${new:-}" ]] || continue
    [[ "$old" == \#* ]] && continue
    printf '\n== %s -> %s\n' "$old" "$new"
    "$M" "$old" "$new" "$@"
    n=$((n + 1))
done < "$QUEUE"

printf '\nReplayed %d queued migration(s).\n' "$n"
# Slug for this machine's home, matching lib/hq.sh cc_slug (tr -c '[:alnum:]' '-').
home_slug="$(printf '%s' "$HOME" | tr -c 'a-zA-Z0-9' '-')"
echo "Verify:  ls ~/.claude/projects/ | grep -c -- '$home_slug'"

# The loop reached here, so `set -e` did not abort on a mid-pass failure: every
# line is applied or was intentionally skipped. Nothing is still pending, so the
# queue is obsolete and gets removed. A mid-pass die leaves it for inspection;
# re-running no-ops the applied lines until the failing one is resolved.
if [[ "$dry" == 1 ]]; then
    echo "Then:    --dry-run — queue left in place."
else
    rm -f "$QUEUE"
    echo "Then:    queue fully applied and removed."
fi
