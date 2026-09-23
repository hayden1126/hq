# Registry

Every project on this machine, one block each. Paths are `$HOME`-relative so this file survives a
directory move. This is the example; the real one is `REGISTRY.md` and is gitignored.

Fields:
- `path` — where it is right now, relative to `$HOME`. `hq-move` keeps this current.
- `status` — `active` or `archived`.
- `docs` — the files to read first when routing a question here.
- `vault` — optional link into a career vault entry.
- `career: no` — this project should never get a vault entry (client work, throwaway).
- `summary` — one or two lines. This is what routing matches against, so make it specific.

## example-project
- path: code/example-project
- status: active
- docs: STATUS.md, SPEC.md
- vault: projects/example-project.md
- summary: A CLI that does the thing. Rust core with a Python wrapper.

## old-coursework
- path: archive/writing/2025-some-class
- status: archived
- career: no
- summary: Finished essay for a class. Kept for reference, never reopened.
