# Shared helpers. Sourced by every bin/hq-* script.
# shellcheck shell=bash

set -euo pipefail

HQ_ROOT="${HQ_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
HQ_REGISTRY="$HQ_ROOT/REGISTRY.md"
HQ_LAYOUT="$HQ_ROOT/layout.toml"
HQ_CC_QUEUE="$HQ_ROOT/pending-cc-migration.tsv"
HQ_SOURCES="$HQ_ROOT/SOURCES.md"
HQ_FLOWS="$HQ_ROOT/FLOWS.md"

die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
warn() { printf '\033[33mwarn:\033[0m  %s\n' "$*" >&2; }
info() { printf '%s\n' "$*"; }
ok()   { printf '\033[32m✓\033[0m %s\n' "$*"; }

# --- platform portability -------------------------------------------------
# The scripts target Linux (GNU coreutils) and macOS (BSD userland). The few
# places the two diverge are resolved once, here, rather than branched at every
# call site. Everything below is bash 3.2 safe (macOS ships 3.2), so no
# `mapfile`, no `${v,,}`, no negative array indices.

# _hq_stat_mtime: argv prefix that prints a file's mtime as epoch seconds.
# GNU is `stat -c %Y`, BSD is `stat -f %m`. Probed once.
if stat -c %Y . >/dev/null 2>&1; then
    _hq_stat_mtime=(stat -c %Y)
else
    _hq_stat_mtime=(stat -f %m)
fi

# hq_sed_inplace EXPR FILE... — in-place sed. GNU takes `-i`, BSD needs `-i ''`.
# GNU sed answers --version; BSD sed does not.
if sed --version >/dev/null 2>&1; then
    hq_sed_inplace() { sed -i "$@"; }
else
    hq_sed_inplace() { local expr="$1"; shift; sed -i '' "$expr" "$@"; }
fi

# hq_real_home — the invoking user's home from the account database, NOT $HOME
# (which a sandbox or test redirects). getent on Linux, dscl on macOS.
hq_real_home() {
    local u; u="$(id -un)"
    if command -v getent >/dev/null 2>&1; then
        getent passwd "$u" | cut -d: -f6
    elif command -v dscl >/dev/null 2>&1; then
        dscl . -read "/Users/$u" NFSHomeDirectory 2>/dev/null | awk '{print $2}'
    fi
}

# Buckets that hold projects, as declared in the [buckets.*] sections.
buckets() {
    require_layout
    awk -F'"' '
        /^\[buckets\./     { inb = 1; next }
        /^\[/              { inb = 0 }
        inb && /^path[[:space:]]*=/ && !seen[$2]++ { print $2 }
    ' "$HQ_LAYOUT"
}

# Directories deliberately outside the bucket system.
exempt_paths() {
    require_layout
    awk -F'"' '/^\[\[exempt\]\]/ { inx = 1; next }
               inx && /^path[[:space:]]*=/ { print $2; inx = 0 }' "$HQ_LAYOUT"
}

exempt_reason() {
    awk -F'"' -v want="$1" '
        /^\[\[exempt\]\]/ { p = ""; next }
        /^path[[:space:]]*=/  { p = $2; next }
        /^reason[[:space:]]*=/ && p == want { print $2; exit }
    ' "$HQ_LAYOUT"
}

# bucket_archive <bucket> -- where that bucket's finished work goes, empty when
# it has none. Scoped to the [buckets.*] sections, so an [[exempt]] path cannot
# set the key this reads; three callers used to carry their own copy of it.
bucket_archive() {
    awk -F'=' -v want="$1" '
        /^\[buckets\./ { inb = 1; p = ""; next }
        /^\[/           { inb = 0 }
        inb && /^path[[:space:]]*=/ { gsub(/["[:space:]]/, "", $2); p = $2; next }
        inb && /^archives[[:space:]]*=/ && p == want {
            gsub(/["[:space:]]/, "", $2); print $2; exit
        }
    ' "$HQ_LAYOUT"
}

# bucket_registers <bucket> -- false only when the bucket declares
# `registers = false`. Buckets require registration unless they opt out, so
# declaring a new bucket does not also mean remembering a new key.
bucket_registers() {
    local v
    v="$(awk -F'=' -v want="$1" '
        /^\[buckets\./ { inb = 1; p = ""; next }
        /^\[/           { inb = 0 }
        inb && /^path[[:space:]]*=/ { gsub(/["[:space:]]/, "", $2); p = $2; next }
        inb && /^registers[[:space:]]*=/ && p == want {
            gsub(/["[:space:]]/, "", $2); print $2; exit
        }
    ' "$HQ_LAYOUT")"
    [[ "$v" != "false" ]]
}

require_registry() {
    [[ -f "$HQ_REGISTRY" ]] || die "no registry at $HQ_REGISTRY — run hq-bootstrap first"
}

require_layout() {
    [[ -f "$HQ_LAYOUT" ]] || die "no layout.toml at $HQ_LAYOUT — run hq-bootstrap first"
}

# Every registered project name.
reg_names() {
    require_registry
    awk '/^## / { print $2 }' "$HQ_REGISTRY"
}

reg_has() {
    reg_names | grep -qxF "$1"
}

# Every registered path, in file order. Directories are identified by path and
# entries by name, and the two differ often enough to matter: 'essay' lives at
# archive/writing/history-paper. Anything checking "is this directory
# registered" must compare paths, never basenames.
reg_paths() {
    require_registry
    awk '/^- path:[[:space:]]*/ { sub(/^- path:[[:space:]]*/, ""); print }' "$HQ_REGISTRY"
}

# reg_field <name> <field> — one field from one entry, empty if absent.
reg_field() {
    require_registry
    awk -v want="$1" -v key="$2" '
        /^## / { inblock = ($2 == want); next }
        inblock && $0 ~ "^- " key ":" {
            sub("^- " key ":[[:space:]]*", "")
            print
            exit
        }
    ' "$HQ_REGISTRY"
}

# reg_set_field <name> <field> <value> — rewrite in place, adding the field if missing.
# Writes back through the original inode: a mktemp+mv would install mktemp's
# 0600 mode and detach any hardlink.
reg_set_field() {
    local name="$1" key="$2" val="$3" tmp
    require_registry
    reg_has "$name" || die "not registered: $name"
    tmp="$(mktemp)"
    awk -v want="$name" -v key="$key" -v val="$val" '
        /^## / {
            if (inblock && !done) { print "- " key ": " val; done = 1 }
            inblock = ($2 == want)
            if (inblock) done = 0
            print; next
        }
        inblock && $0 ~ "^- " key ":" { print "- " key ": " val; done = 1; next }
        { print }
        END { if (inblock && !done) print "- " key ": " val }
    ' "$HQ_REGISTRY" > "$tmp"
    cat "$tmp" > "$HQ_REGISTRY" && rm -f "$tmp"
}

# Absolute path of a registered project.
reg_abspath() {
    local p; p="$(reg_field "$1" path)"
    [[ -n "$p" ]] || die "no path recorded for $1"
    printf '%s/%s\n' "$HOME" "$p"
}

# Every MCP server named in SOURCES.md, one per line, deduped. The calendar
# entry lists three servers on a single `server:` line, so split the comma-list;
# the disconnected onenote entry carries the placeholder '(none)', which is not a
# server. Nothing else consumes SOURCES.md today — flow resolution is the first.
src_servers() {
    [[ -f "$HQ_SOURCES" ]] || return 0
    awk '/^- server:/ {
            sub(/^- server:[[:space:]]*/, "")
            n = split($0, a, ",")
            for (i = 1; i <= n; i++) {
                gsub(/[[:space:]]/, "", a[i])
                if (a[i] != "" && a[i] != "(none)") print a[i]
            }
        }' "$HQ_SOURCES" | sort -u
}

src_has_server() { src_servers | grep -qxF "$1"; }

require_flows() { [[ -f "$HQ_FLOWS" ]] || die "no flows at $HQ_FLOWS"; }

# Every declared flow name.
flow_names() {
    require_flows
    awk '/^## / { print $2 }' "$HQ_FLOWS"
}

flow_has() { flow_names | grep -qxF "$1"; }

# flow_field <name> <field> — one field from one flow, empty if absent.
flow_field() {
    require_flows
    awk -v want="$1" -v key="$2" '
        /^## / { inblock = ($2 == want); next }
        inblock && $0 ~ "^- " key ":" {
            sub("^- " key ":[[:space:]]*", "")
            print
            exit
        }
    ' "$HQ_FLOWS"
}

# A flow token names a home. Both resolvers soft-fail (return non-zero) rather
# than die like reg_abspath, so hq-audit can report a dead edge and keep scanning
# the rest of the map.

# flow_resolve_target <token> -> abs path on stdout, non-zero if dead. 'vault' is
# an exempt path (layout.toml), not a registry entry, so it resolves on its own.
flow_resolve_target() {
    local t="$1" p
    if [[ "$t" == vault ]]; then
        [[ -d "$HOME/vault" ]] && { printf '%s\n' "$HOME/vault"; return 0; }
        return 1
    fi
    if reg_has "$t"; then
        p="$(reg_field "$t" path)"
        [[ -n "$p" && -d "$HOME/$p" ]] && { printf '%s\n' "$HOME/$p"; return 0; }
    fi
    return 1
}

# flow_resolve_source <token> -> "<kind>\t<locator>" on stdout, non-zero if dead.
# kind is project | mcp | path; resolution order is registry, then a SOURCES
# server, then a $HOME-relative path (which is how 'vault' resolves as a source,
# ~/vault existing). The path guard is hq-register's: no absolute, ~, or traverse.
flow_resolve_source() {
    local s="$1" p
    if reg_has "$s"; then
        p="$(reg_field "$s" path)"
        [[ -n "$p" && -d "$HOME/$p" ]] && { printf 'project\t%s\n' "$HOME/$p"; return 0; }
        return 1
    fi
    if src_has_server "$s"; then
        printf 'mcp\t%s\n' "$s"; return 0
    fi
    case "$s" in /*|"~"*|*..*) return 1 ;; esac
    [[ -e "$HOME/$s" ]] && { printf 'path\t%s\n' "$HOME/$s"; return 0; }
    return 1
}

# True when a live Claude Code session could clobber the config we are about to
# edit. A running session writes to the invoking user's real home, so a
# redirected $HOME (a sandbox, a test) is never at risk.
#
# HQ_ASSUME_CLAUDE_RUNNING=1 forces the answer. pgrep only sees this machine's
# process table, so a session on another tty, host, or container is invisible
# to it; the override is how you say "defer anyway".
claude_is_running() {
    [[ "${HQ_ASSUME_CLAUDE_RUNNING:-0}" == 1 ]] && return 0
    local real_home
    real_home="$(hq_real_home)"
    [[ "$HOME" == "$real_home" ]] || return 1
    pgrep -x claude >/dev/null 2>&1 || pgrep -f '^claude ' >/dev/null 2>&1
}

# Claude Code names its per-project transcript directory after the absolute
# path with every character outside [A-Za-z0-9-] replaced by '-'. Case is
# preserved. So ~/my_project is stored as -home-<user>-my-project, and a dotted
# directory like ~/.config doubles its separator (-home-<user>--config).
#
# Claude Code also truncates very long slugs (~96 chars); this does not, which
# only matters for deeply nested worktree paths.
cc_slug() {
    printf '%s' "$1" | tr -c 'a-zA-Z0-9' '-'
}

# Record a Claude Code state migration that could not run now, so the work
# survives the terminal it was announced in. Append-only and deduped while it
# waits; pending-cc-migration.sh replays it wholesale, then removes the queue on
# a clean pass, so it never accumulates applied entries. Replay is a no-op for a
# line whose old path is empty, and hq-migrate-cc-state skips one whose old path
# has been reused rather than clobber it.
cc_queue_append() {
    local old="$1" new="$2" line
    line="$(printf '%s\t%s' "$old" "$new")"
    if [[ -f "$HQ_CC_QUEUE" ]] && grep -qxF "$line" "$HQ_CC_QUEUE"; then
        return 0
    fi
    printf '%s\n' "$line" >> "$HQ_CC_QUEUE"
}

# Newest mtime under a directory, as epoch seconds; empty when there are no
# files. `-exec ... {} +` batches like xargs but skips the run entirely on an
# empty match, and `stat` (via _hq_stat_mtime) is the portable stand-in for
# GNU find's `-printf '%T@'`, which BSD find lacks. The awk max is a single
# pass, so there is no `sort | head` to take SIGPIPE under `set -o pipefail`.
newest_mtime() {
    find "$1" -type f -not -path '*/.git/*' -not -path '*/node_modules/*' \
        -not -path '*/.venv/*' -exec "${_hq_stat_mtime[@]}" {} + 2>/dev/null |
        awk '$1 > m { m = $1 } END { if (m > 0) print m }'
}

# Abort if any process has its cwd inside a directory, which makes moving it
# unsafe. Linux reads /proc directly (fast, exact); macOS has no /proc, so it
# falls back to `lsof -d cwd`, present on both but slower. If neither is
# available the check cannot run and does not block.
assert_no_processes_in() {
    local dir="$1" blockers="" p cwd
    if [[ -d /proc ]]; then
        for p in /proc/[0-9]*; do
            cwd="$(readlink "$p/cwd" 2>/dev/null)" || continue
            case "$cwd" in
                "$dir"|"$dir"/*) blockers+="  pid ${p#/proc/} cwd=$cwd"$'\n' ;;
            esac
        done
    elif command -v lsof >/dev/null 2>&1; then
        blockers="$(lsof -a -d cwd +D "$dir" 2>/dev/null |
            awk 'NR > 1 { print "  pid " $2 " (" $1 ")" }' | sort -u)"
    fi
    [[ -z "$blockers" ]] || die "processes are running inside $dir:"$'\n'"$blockers"
}
