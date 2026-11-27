# AGENTS.md — emacs-git-bug

## Purpose

`git-bug.el`: Emacs Lisp package, a Magit extension that inserts a "Bugs" section
into `magit-status` through `magit-status-sections-hook`. Emacs 31.1 or newer.
License: AGPL-3.0-or-later.

## Layout

- `git-bug.el` — the package: sections, commands, CLI wrapper, viewer and compose
  modes, and the public library entry points listed in the README `* Library`
  section.
- `test/git-bug-test.el` — ERT suite. Most tests drive the real `git-bug`
  binary in a throwaway repo; the heading layout test renders fabricated bug
  lists, so column alignment is asserted without a repository.
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
- Cache details by repository, full id and edit time, and serve them while
  `git-bug-detail-ttl` allows. Report every real change through
  `git-bug-change-functions`; a write refreshes its own cache entry first, so a
  fetch that returns cached content stays silent. Refresh the package's own
  views before running the hook, so replacing the hook cannot stop a write from
  updating them.
- Route subprocesses through `git-bug--call-with-input` for quiet git settings,
  UTF-8 coding and stdin support. Signal a subtype of `git-bug-error`, with the
  call context attached, rather than a generic error.
- Put faces on `font-lock-face`, never on `face`. Font-lock strips `face` on
  refontification. Bug bodies are fontified with the builtin `markdown-ts-mode`.
- Keep Markdown fontification sandboxed: no native code blocks, inline images,
  remote images or folding.

## Conventions

- Prefix `git-bug-` for commands and `git-bug--` for internals.
- The bare-name entries of the README `* Library` section are the public
  surface: `git-bug-list`, `git-bug-get`, `git-bug-field`, `git-bug-format-bug`,
  `git-bug-format-bug-list`, `git-bug-buffer`, `git-bug-show`,
  `git-bug-forget`, `git-bug-error-data`. Everything else stays `git-bug--`.
  Keep the Library section and the `git-bug-tests-library-*` tests in step with
  every new entry point.
- Prefer a pure renderer returning text over a function that inserts into the
  current buffer; a string must not need a buffer to build.
- Docstrings: imperative function summaries, noun-phrase variable summaries,
  `When non-nil, ...' flag summaries. Keep summary lines under 80 columns.

## Workflow

- Bugs for this repo live in git-bug itself. Never sync `refs/bugs/*` to any
  remote.
