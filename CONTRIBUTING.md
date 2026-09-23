# Contributing

Thanks for looking. hq is a small, dependency-light set of shell scripts; the bar is that it stays
that way.

## Before you push

```bash
./test/run.sh                                   # the full suite (plain shell, no deps)
shellcheck bin/hq-* lib/hq.sh install.sh pending-cc-migration.sh hooks/pre-push
./bin/hq-publish-check                           # no private data in the publishable tree
```

All three must pass. `hq-publish-check` also runs as part of `test/run.sh`, and the pre-push hook
(`hooks/pre-push`, enabled by `install.sh`) runs it again on every push.

## Ground rules

- **No personal data in tracked files.** Anything machine- or account-specific lives in a gitignored
  file with a generic `*.example.*` twin that ships in its place (`REGISTRY.md` →
  `REGISTRY.example.md`, `CLAUDE.md` → `CLAUDE.example.md`, `layout.toml` → `layout.example.toml`, and
  so on). `hq-bootstrap` seeds the real file from the twin. If you add a new per-machine file, add the
  twin, the `.gitignore` line, the bootstrap seed, and a `hq-publish-check` entry.
- **Portable shell, Linux and macOS.** Scripts must run under **bash 3.2** (macOS default) with both
  GNU and BSD userland. No `mapfile`/`readarray`, no `${v,,}`, no negative array indices. Where GNU and
  BSD diverge (`stat`, `sed -i`, `readlink -f`, `find -printf`, `getent`, `/proc`), use the shims in
  `lib/hq.sh` (`_hq_stat_mtime`, `hq_sed_inplace`, `hq_real_home`, `assert_no_processes_in`) rather
  than branching at the call site.
- **`layout.toml` is the single contract.** Bucket names and exempt paths are declared there and read
  by both the scripts and the skill. Don't hardcode a bucket name in a script.
- **Tests are plain shell.** Each runs against a throwaway `$HOME`; see `test/run.sh`. Add a
  `test_*` function and the runner discovers it.

## What this repo is not

hq manages a home directory's structure and routes an agent over it. It is deliberately not a package
manager, a dotfiles framework, or a secrets store. Features that pull in a runtime dependency or reach
into another tool's private on-disk format need a strong reason.
