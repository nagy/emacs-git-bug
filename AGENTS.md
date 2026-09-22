# AGENTS.md

Emacs Lisp package `git-bug.el`: Magit extension inserting a "Bugs"
section into `magit-status` via `magit-status-sections-hook`.

## Commands

- `nix flake check` — package (byte-compile, warnings as errors) + ERT
  suite + checkdoc + package-lint.  Meaningful gate; run before done.
- `nix build` — the melpaBuild package (runs the ERT suite too).
- `nix fmt` — treefmt/nixfmt; never run formatters standalone.
- Ad-hoc test run: `emacs -Q --batch -L . -l git-bug-tests.el -f ert-run-tests-batch-and-exit`
  (needs `git` and `git-bug` on PATH).

## Layout

- `git-bug.el` — the package (sections, commands, CLI wrapper).
- `git-bug-tests.el` — ERT suite; each test drives the real `git-bug`
  binary in a throwaway repo.
- `flake.nix` — everything Nix: melpaBuild with `substituteInPlace`
  patching `git-bug-program` to the `pkgs.git-bug` store path,
  checks, devShell, treefmt.

## Conventions

- License AGPL-3.0-or-later; keep the full header in every .el file.
- `turnCompilationWarningToError` stays on; fix warnings, do not silence.
- Prefix `git-bug-` / `git-bug--`; keep checkdoc and package-lint clean.
- Bugs for this repo are tracked with git-bug itself; never sync
  `refs/bugs/*` to any remote.
