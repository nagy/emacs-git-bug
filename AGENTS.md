# AGENTS.md

Emacs Lisp package `git-bug.el`: Magit extension inserting a "Bugs"
section into `magit-status` via `magit-status-sections-hook`.

## Commands

- `nix flake check` — package (byte-compile, warnings as errors) + ERT
  suite + checkdoc + package-lint.  Meaningful gate; run before done.
- `nix build` — the melpaBuild package (runs the ERT suite too).
- `nix fmt` — treefmt/nixfmt; never run formatters standalone.
- Ad-hoc test run inside `nix develop`:
  `emacs -Q --batch -L . -L test --eval '(setq treesit-extra-load-path (list (getenv "MARKDOWN_GRAMMARS")))' -l test/git-bug-test.el -f ert-run-tests-batch-and-exit`
  (needs `git` and `git-bug` on PATH).

## Layout

- `git-bug.el` — the package (sections, commands, CLI wrapper,
  viewer and compose modes).
- `test/git-bug-test.el` — ERT suite; each test drives the real `git-bug`
  binary in a throwaway repo.
- `flake.nix` — everything Nix: an overridable package built with
  `lib.makeOverridable` (`emacs`, `emacsPackages`, `melpaBuild`,
  `markdownGrammars`, `version` arguments), `substituteInPlace`
  patching `git-bug-program` to the `pkgs.git-bug` store path,
  checks, devShell, treefmt.  The dev shell provides Magit and the
  tree-sitter `markdown`/`markdown-inline` grammars (renamed
  `parser` files) for `treesit-extra-load-path`.

## Conventions

- Emacs 31.1 minimum: bug bodies are fontified with the builtin
  `markdown-ts-mode`; faces go on `font-lock-face`, never `face`
  (font-lock strips `face` on refontification).
- License AGPL-3.0-or-later; keep the full header in every .el file.
- `turnCompilationWarningToError` stays on; fix warnings, do not silence.
- Prefix `git-bug-` / `git-bug--`; keep checkdoc and package-lint clean.
- Tests live in `test/`, one `*-test.el` per source unit.  The
  `checkPhase` loads them with a `test/*-test.el` glob, so a new test
  file needs no flake edit.  Lint covers `test/*.el`.
- Docstrings: imperative function summaries, noun-phrase variable
  summaries, `When non-nil, ...' flag summaries; keep summary lines
  under 80 columns.
- Use full bug ids for CLI calls.  Keep `human_id` for display and
  copying.
- Load details through `magit-insert-section-body`; never run
  `git-bug bug show` for collapsed sections.
- Cache details by repository, full id and edit time.  Force a fetch
  after writes and on explicit refresh.
- Keep Markdown fontification sandboxed: no native code blocks, inline
  images, remote images or folding.
- Route subprocesses through `git-bug--call-with-input` for quiet git
  settings, UTF-8 coding and stdin support.
- Bugs for this repo are tracked with git-bug itself; never sync
  `refs/bugs/*` to any remote.
