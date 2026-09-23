# Flows

Directed cross-home data flows hq brokers, the way `REGISTRY.md` maps projects and `SOURCES.md` maps
external sources. hq reads the SOURCE with its own creds/tools, then dispatches an agent rooted in the
TARGET so the target's own rules govern the write. One block each. Direction is always source ->
target: a target never reaches up to a source. This is the example; the real file is `FLOWS.md`,
gitignored because it names real projects and accounts.

Fields:
- `source`: a `REGISTRY.md` name, a `SOURCES.md` `server:` token (e.g. `gw-example`, not the
  `## gmail-example` heading), or a `$HOME`-relative path. This is where hq reads, in the hq session.
- `target`: a `REGISTRY.md` name, or the literal `vault`. This is where the write lands.
- `direction`: always `source -> target`. Recorded so the one-way rule is legible.
- `scope`: human text (which folder, which inbox query, which files). hq prints it; it is not resolved.
- `governance`: `target-rules` (the target's own CLAUDE.md governs, or the global one if it has none)
  or `vault-gate` (observable + cited, `> NEEDS INPUT` for anything evaluative, never commit, leave
  the diff).
- `read-with`: optional. The tool family hq reads the source with. Derived when omitted
  (`mcp__<server>__*` for a source server, `Read` for a project or a path).

## example-inbox-to-project
- source: gw-example
- target: example-project
- direction: source -> target
- scope: the "Deadlines" label in the example inbox
- governance: target-rules
- read-with: mcp__gw-example__*

## example-vault-from-project
- source: example-project
- target: vault
- direction: source -> target
- scope: STATUS.md and the release notes under the project
- governance: vault-gate
- read-with: Read
