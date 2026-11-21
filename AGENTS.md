# AGENTS.md — emacs-git-bug

## Purpose

`git-bug.el`: Emacs Lisp package, a Magit extension that inserts a "Bugs" section
into `magit-status` through `magit-status-sections-hook`. Emacs 31.1 or newer.
License: AGPL-3.0-or-later.

## Layout

- `git-bug.el` — the package: sections, commands, CLI wrapper, viewer and compose
  modes.
- `test/git-bug-test.el` — ERT suite. Each test drives the real `git-bug` binary
  in a throwaway repo.
- `flake.nix` — everything Nix: an overridable package built with
  `lib.makeOverridable` (`emacs`, `emacsPackages`, `melpaBuild`,
  `markdownGrammars`, `version` arguments), `substituteInPlace` patching
  `git-bug-program` to the `pkgs.git-bug` store path, checks, devShell, treefmt.
  The dev shell provides Magit and the tree-sitter `markdown`/`markdown-inline`
  grammars (renamed `parser` files) for `treesit-extra-load-path`.

## Build and test

- `nix flake check` — the gate. Run before done.
- `nix build` — the melpaBuild package. Runs the ERT suite too.
- `nix fmt` — treefmt and nixfmt. Never run formatters standalone.
- Ad-hoc run inside `nix develop`:
  `emacs -Q --batch -L . -L test --eval '(setq treesit-extra-load-path (list (getenv "MARKDOWN_GRAMMARS")))' -l test/git-bug-test.el -f ert-run-tests-batch-and-exit`.
  Needs `git` and `git-bug` on `PATH`.

## Rules

- Never silence a byte-compile warning. Fix it.
- Keep the full AGPL-3.0-or-later header in every `.el` file.
- Tests live in `test/`, one `*-test.el` per source unit. The `checkPhase` loads
  them with a `test/*-test.el` glob, so a new test file needs no flake edit. Lint
  covers `test/*.el`.
- Use full bug ids for CLI calls. Keep `human_id` for display and copying.
- Load details through `magit-insert-section-body`. Never run `git-bug bug show`
  for a collapsed section.
- Cache details by repository, full id and edit time. Force a fetch after writes
  and on explicit refresh.
- Route subprocesses through `git-bug--call-with-input` for quiet git settings,
  UTF-8 coding and stdin support.
- Put faces on `font-lock-face`, never on `face`. Font-lock strips `face` on
  refontification. Bug bodies are fontified with the builtin `markdown-ts-mode`.
- Keep Markdown fontification sandboxed: no native code blocks, inline images,
  remote images or folding.

## Conventions

- Prefix `git-bug-` for commands and `git-bug--` for internals.
- Docstrings: imperative function summaries, noun-phrase variable summaries,
  `When non-nil, ...' flag summaries. Keep summary lines under 80 columns.

## Workflow

- Bugs for this repo live in git-bug itself. Never sync `refs/bugs/*` to any
  remote.
