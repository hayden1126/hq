# hq

A home directory that organises itself, and an agent that knows where everything is.

`~/` accumulates. Projects, clones, coursework, and tool-installed caches all land at the same level
until finding anything requires already knowing it exists. `hq` fixes that with three parts: a small
set of buckets, a registry of what lives where, and scripts that move things correctly instead of
with a bare `mv`.

## Layout

```
~/
├── code/          authored code, still open
├── writing/       prose, plus library/ for reading attached to no piece
├── archive/       finished work, mirroring the active buckets
│   ├── code/
│   └── writing/
├── scratch/       throwaway
└── hq/            this repo
```

`archive/` mirrors the active buckets rather than inventing its own taxonomy, so nothing needs
reclassifying on the way in. Where a new thing goes is a question with one answer.

These bucket names and paths are not hardcoded: they are declared in `layout.toml`, the one file the
scripts and the skill share. Change the names, add or drop a bucket, or edit the exempt list there and
everything follows. `layout.toml` is per-machine (its exempt list names your own tool-owned
directories), so it is gitignored; `layout.example.toml` ships the format and `hq-bootstrap` seeds
your copy from it on first run. Edit the copy.

## Requirements

- **bash** (3.2+, so the macOS default works), **git**, and a standard **coreutils** userland.
  Runs on **Linux and macOS**; the few GNU/BSD differences are handled internally.
- **`python3`** only for one thing: migrating Claude Code's per-project state during `hq-move`
  (`hq-migrate-cc-state`). Everything else works without it.
- No package to install and no runtime dependency beyond the above.

## Install

```bash
git clone https://github.com/hayden1126/hq.git ~/hq
~/hq/install.sh          # creates the buckets, links the skill, adds bin/ to PATH, enables the pre-push gate
```

`install.sh` is idempotent and never overwrites an existing directory. It runs `hq-bootstrap`, which
seeds the three per-machine core files from their shipped examples if they are absent: `layout.toml`
(from `layout.example.toml`), `CLAUDE.md` (from `CLAUDE.example.md`), and `REGISTRY.md` (from
`REGISTRY.example.md`). Edit those copies; they are gitignored. Cloning elsewhere than `~/hq` works
too: the PATH line points at wherever you cloned.

## Commands

| | |
|---|---|
| `hq-audit` | drift: unregistered dirs, dead entries, projects gone quiet, vault mismatches, dead flow edges |
| `hq-new <name> [bucket] [--git]` | scaffold a new project and register it |
| `hq-register <name> <path> [summary]` | adopt a directory that already exists, such as a clone |
| `hq-move <name> <dest>` | move a project *and* repair what a bare `mv` would break |
| `hq-archive <name>` | active → archive, same repairs |
| `hq-sync-vault [name]` | refresh observable facts in a career vault, if you keep one |
| `hq-flow [name]` | resolve a declared cross-home flow to its source, target, and rules |
| `hq-bootstrap` | create the buckets (run by `install.sh`) |
| `hq-state <cmd>` | version the private files in a separate private repo (see below) |
| `hq-publish-check` | pre-publish gate: no private strings, private files ignored, layers disjoint |
| `hq-migrate-cc-state <old> <new>` | move Claude Code's per-project state between two paths |
| `./pending-cc-migration.sh` | replay migrations `hq-move` had to defer (see below) |

## Cloning a project

`hq-new` creates a project. `hq-register` adopts one that is already on disk, which is what cloning
produces. Clone into the bucket, then register:

```bash
git clone git@github.com:someone/thing.git ~/code/thing
hq-register thing code/thing "What it is, in one line."
```

The summary is what routing matches against, so an entry without one is effectively unfindable.
`hq-register` fills in `docs:` from whichever of `CLAUDE.md`, `STATUS.md`, `SPEC.md`, `PLAN.md` and
`README.md` it finds, and it refuses a path another entry already claims, because one directory with
two entries is how a registry starts lying.

`hq-register` writes no `career:` or `vault:` field, on purpose: that field is a forcing function, so
the next `hq-audit` asks you to decide once rather than deciding for you. Until you answer, the audit
exits non-zero. Registering outside a bucket warns instead of refusing, because cloning to `~/thing`
and then `hq-move`-ing it in is a legitimate two-step.

If you forget to register it, `hq-audit` says so. Its unregistered-directory check covers the top
level, plus one level inside each bucket that requires registration and inside that bucket's archive:
`code`, `archive/code`, `writing`, `archive/writing` here. `scratch` opts out with
`registers = false`, since nothing there is meant to survive. One level and no deeper, so the repos
nested inside a project stay invisible.

## Why `hq-move` and not `mv`

Moving a project directory silently breaks more than it looks like it should:

- **Python editable installs.** A `.pth` file naming a directory that no longer exists is discarded
  by `site.py` with no warning. The import just stops working.
- **Virtualenvs.** `bin/activate` hardcodes `VIRTUAL_ENV`, and every console script carries an
  absolute shebang.
- **Symlinks on `PATH`.** Anything in `~/.local/bin` pointing into the project tree dangles.
- **Claude Code state.** Session history and permissions are keyed by absolute path, so a moved
  project silently starts over with no history.

`hq-move` handles each of these. That is the entire reason it exists.

### The one step it cannot always finish

Claude Code rewrites `~/.claude.json` from memory when a session exits, so editing that file while a
session is live loses the edit. If you run `hq-move` from inside Claude Code — the normal case —
it therefore **defers** the state migration instead of performing it, appending the old and new
paths to `pending-cc-migration.tsv`.

A warning printed to a terminal is a warning nobody reads twice, so the deferral is recorded on
disk. Finish it later from a plain shell with no session open:

```bash
~/hq/pending-cc-migration.sh      # replays the queue, skips any path since reused, clears itself on a clean pass
```

Until you do, the moved project's history and trust settings still point at the old path.

## Registry

`REGISTRY.md` is this machine's project list and is **gitignored** — it names real work and may
point at private material. `REGISTRY.example.md` ships in its place and shows the format. Paths are
`$HOME`-relative so the file survives the directory moving.

## Private state: a second repo over the same tree

hq's per-machine files (`REGISTRY.md`, `SOURCES.md`, `CLAUDE.md`, `layout.toml` and the rest) are
gitignored, so the code repo never sees them. That keeps them out of any public history, but it also
leaves them unversioned. `hq-state` fixes that with a second git repository over the same work tree:
its git dir is `.state.git/` (ignored by the code repo), and it tracks only the files you add to it.

```bash
hq-state init                        # once, on the first machine
hq-state add REGISTRY.md SOURCES.md  # track private files (files, not directories)
hq-state remote add origin <your private repo url>
hq-state push -u origin HEAD
hq-state sync --push "snapshot"      # commit all edits, plus new files in tracked directories
```

`sync` suits a Claude Code `SessionEnd` hook: it snapshots every tracked file and adopts new files
only inside a directory the overlay already tracks (a new memory note, a new local doc), never a new
location. To version Claude Code's project memory for hq, move it to `.claude/memory/` (ignored by
the code repo), symlink `~/.claude/projects/<slug>/memory` to it, and `hq-state add` its files once.

Every other subcommand is plain git against the overlay (`status`, `diff`, `log`, `pull`). The two
layers never cross. `hq-state add` refuses a file the code repo tracks or would publish, and
`hq-publish-check` fails if the overlay ever tracks one, so a private file cannot reach the public
history and a code file cannot fork into the private one.

**On a new machine,** restore the overlay right after cloning:

```bash
git clone https://github.com/hayden1126/hq.git ~/hq
~/hq/bin/hq-state restore <your private repo url>
~/hq/install.sh
```

`restore` never overwrites a file already on disk; one that differs shows up in `hq-state diff`.
Restoring before `install.sh` means the bootstrap finds your real files and seeds nothing.

## The pre-push gate

`install.sh` sets `core.hooksPath=hooks`, which runs the tracked `hooks/pre-push` on every push of the
code repo. It blocks the push unless `hq-publish-check` passes on the tree and no outgoing commit
carries a denylisted string in its message or added lines. If you keep an older, private history of
the code in the same clone, tag its tip `private-history`: the hook refuses any commit that shares
history with it, so a stray `git push --tags` cannot publish it.

## Optional: a career vault

The vault is a **separate repository you own**, checked out at `~/vault`; hq never contains it and
only references it by path. If you keep one, `hq-sync-vault` reports which of its observable facts
(versions, ship dates, languages) have fallen behind their repo, and the refresh is done by an agent
under the vault's own rules: cite every fact, file anything evaluative as a `> NEEDS INPUT` line, and
leave an uncommitted diff. hq never commits into the vault and never invents. If you have no vault,
ignore it — everything vault-related no-ops gracefully. Full contract: `docs/vault.md`.

## Optional: external sources

hq can also route over sources that are not files: a Notion workspace, Gmail, and Google Calendar,
reached over MCP. Optional and off by default; a fresh clone has none of it.

The model mirrors the registry. `SOURCES.md` maps each source (what it holds, read or write, which
tools reach it) the way `REGISTRY.md` maps projects, and is gitignored for the same reason, it names
personal accounts. `SOURCES.example.md` ships the format. The MCP servers are declared in a gitignored
`.mcp.json` (format in `.mcp.example.json`) scoped to the hq project, so they load only when you work
in hq and never leak into other projects. No secrets enter the repo: OAuth tokens live in per-account
credential dirs and Claude Code's own store, and the two API tokens live in `~/.secrets.env`.

Posture is read-first, with one deliberate write exception: Notion writes to designated pages. Gmail
and Calendar are read-only (no draft, no send). The one-time OAuth setup is in `docs/external-sources-setup.md`.

## Optional: cross-home flows

hq can broker a directed flow between two homes: it reads a source with its own tools, then dispatches
an agent rooted in the target so the target's own rules govern the write. That is how work spanning two
places gets done, pulling a connected Drive's files into a project, refreshing one project from another,
feeding a vault from an inbox, without any project reaching into another or holding a credential it
should not.

`FLOWS.md` is a third map beside `REGISTRY.md` and `SOURCES.md`, declaring `source -> target` edges. It
is gitignored (it names real homes) and `FLOWS.example.md` ships the format. `hq-flow <name>` resolves
a flow to the source, target, and governing rules an agent needs, and `hq-audit` flags a flow whose
source or target no longer resolves. Off by default: a fresh clone has none, and the full rationale is
in `docs/cross-home-flows.md`.

## Relationship to your Claude config

Minimal, and deliberate. `hq` installs its own skill into `~/.claude/skills/hq`, and when you enable
external sources it declares its own project-scoped `.mcp.json` and permissions under `~/hq/.claude/`.
Both are hq owning its own tools, the same move as shipping its own skill; neither touches your global
`~/.claude` config or references your dotfiles repo. hq knows nothing about whatever else manages that
directory, so this repo and your dotfiles repo can still be adopted separately.

## Contributing

Bug reports and small, dependency-light patches welcome. See `CONTRIBUTING.md` for the test,
lint, and portability bar (scripts must run under bash 3.2 on both Linux and macOS, and no personal
data lands in tracked files).

## License

MIT. See `LICENSE`.
