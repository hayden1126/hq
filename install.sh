#!/usr/bin/env bash
# Set up hq on this machine. Idempotent; never overwrites an existing directory.
set -euo pipefail

HQ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"$HQ_ROOT/bin/hq-bootstrap"

# The pre-push gate (hooks/pre-push runs hq-publish-check). Git does not version
# hook wiring, so point this clone's hooks at the tracked hooks/ directory.
if git -C "$HQ_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    git -C "$HQ_ROOT" config core.hooksPath hooks
    echo "✓ pre-push gate enabled (core.hooksPath=hooks)"
fi

# The routing skill. hq ships and installs its own, and deliberately knows
# nothing about whatever else manages ~/.claude — per-entry linking means a
# config repo managing that directory will leave this alone.
skills_dir="$HOME/.claude/skills"
if [[ -d "$HOME/.claude" ]]; then
    mkdir -p "$skills_dir"
    ln -sfn "$HQ_ROOT/skills/hq" "$skills_dir/hq"
    echo "✓ linked skill -> ~/.claude/skills/hq"
else
    echo "note: no ~/.claude found, skipping skill install (Claude Code not set up here)"
fi

# PATH, appended once. Point at the actual clone location (this works cloned
# anywhere, not only ~/hq): $HOME-relative when it sits under $HOME so the line
# survives a home move, absolute otherwise.
if [[ "$HQ_ROOT" == "$HOME/"* ]]; then
    bindir="\$HOME/${HQ_ROOT#"$HOME"/}/bin"
else
    bindir="$HQ_ROOT/bin"
fi
line="export PATH=\"$bindir:\$PATH\""
for rc in "$HOME/.zshrc" "$HOME/.bashrc"; do
    [[ -f "$rc" ]] || continue
    if grep -qF "$line" "$rc"; then
        echo "✓ PATH already set in $(basename "$rc")"
    else
        printf '\n# hq\n%s\n' "$line" >> "$rc"
        echo "✓ added $bindir to PATH in $(basename "$rc")"
    fi
done

echo
echo "Done. Open a new shell, then run: hq-audit"
