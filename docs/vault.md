# Optional: the career vault

The vault is a **separate repository you own**, checked out at `~/vault`. hq never contains it and
never commits into it; hq only references it by path. Everything vault-related in hq no-ops gracefully
when `~/vault` is absent, so this whole layer is opt-in.

Keep it separate on purpose: the vault holds career facts (and often PII), and lives under its own
`CLAUDE.md` with stricter rules than hq's. hq's job is to keep the vault's *observable* facts fresh
from your repos; the vault's job is to be the single source of truth for a CV or a personal site.

## What hq expects at `~/vault`

- **`~/vault/projects/*.md`** — one fact-file per career-relevant project. Each records observable
  facts (languages, ship dates, versions) with a citation for each.
- **A back-reference from the registry.** A project's `REGISTRY.md` entry points at its fact-file with
  `vault: projects/<slug>.md`. `hq-audit`'s vault cross-check validates this both ways: a registered
  project with neither a `vault:` entry nor `career: no` is flagged, and a `projects/*.md` file that
  matches no registry entry is flagged.
- **A `synced-from:` stamp** in each fact-file, of the form `synced-from: <name>@<short-sha>`.
  `hq-sync-vault` compares the `<short-sha>` after the `@` against the repo's current `git HEAD` and
  reports how many commits the facts have fallen behind.

## Two frontmatter markers (different axes)

- **`mirrored: false`** — the repo has *no local checkout on this machine* (remote-only). There is
  nothing to sync from, so `hq-audit` skips it instead of flagging it as an orphan. This is the marker
  for a remote-only repo, not a registry entry whose path is missing.
- **`external: true`** — the repo is *owned by a collaborator*. A separate axis: an external repo
  normally stays checked out and registered. `external` is **not** a substitute for `mirrored: false`;
  a file carrying only `external` still needs a registry match or it is treated as drift.

## The vault gate (how writes happen)

hq never writes vault prose directly. `hq-sync-vault` only **reports** what has fallen behind; the
actual refresh is done by an agent dispatched into `~/vault` under the vault's own **`project-sync`
skill** (`~/vault/.claude/skills/project-sync`), which you provide in your vault repo. That agent:

- writes only facts it can cite (a git tag, `pyproject.toml`, `STATUS.md`),
- files anything evaluative as a `> NEEDS INPUT` line for you, never as prose,
- leaves the diff uncommitted for your review.

The same gate applies to any cross-home flow whose `target` is `vault` (see `docs/cross-home-flows.md`):
observable, cited, `> NEEDS INPUT` for judgement, never commit.

## Setting one up

1. Create a repo and check it out at `~/vault`.
2. Add it to `layout.toml`'s exempt list (the shipped `layout.example.toml` already lists `vault`).
3. Add a `projects/<slug>.md` fact-file per project, and a `vault: projects/<slug>.md` line to the
   matching `REGISTRY.md` entry (or mark the entry `career: no` if it should never have one).
4. Provide a `project-sync` skill in the vault for the write step.
5. Run `hq-sync-vault` to see what is stale.
