{
  description = "Magit status sections for the git-bug bug tracker (Emacs package)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      # One nixpkgs closure, no duplicates.
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{
      flake-parts,
      nixpkgs,
      treefmt-nix,
      ...
    }:
    # Modification date of the flake source as YYYY-MM-DD, folded
    # into the version string below.  Flake source info gives it as
    # e.g. "20260922133522".  A plain path import has no git
    # metadata, so fall back to the epoch instead of failing.
    let
      sourceInfo = inputs.self.sourceInfo or { };
      lastModifiedDate = sourceInfo.lastModifiedDate or "19700101000000";
      commitDate = "${builtins.substring 0 4 lastModifiedDate}-${
        builtins.substring 4 2 lastModifiedDate
      }-${builtins.substring 6 2 lastModifiedDate}";
      version = "0.1.0-unstable-${commitDate}";

      # Tree-sitter grammars for the markdown fontification of bug
      # bodies, renamed to the "libtree-sitter-<lang>.so" names treesit
      # loads: the grammar packages ship the shared object as a bare
      # "parser" file.
      mkMarkdownGrammars =
        pkgs:
        pkgs.runCommand "tree-sitter-markdown-grammars" { } ''
          mkdir -p $out
          ln -s ${pkgs.tree-sitter-grammars.tree-sitter-markdown}/parser \
            $out/libtree-sitter-markdown.so
          ln -s ${pkgs.tree-sitter-grammars.tree-sitter-markdown-inline}/parser \
            $out/libtree-sitter-markdown-inline.so
        '';
    in
    flake-parts.lib.mkFlake { inherit inputs; } {
      # Emacs packages are pure Elisp: no ELF binaries, so evaluate on
      # every Linux arch (and darwin if the deps exist there).
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      perSystem =
        {
          pkgs,
          lib,
          config,
          ...
        }:
        let
          # The package stays overridable, so a consumer can swap the
          # Emacs, its package set or the grammar set:
          #   inputs.git-bug.packages.${system}.git-bug.override {
          #     emacs = pkgs.emacs-nox;
          #   }
          # The flake passes the commit-derived version, because a plain
          # import of the expression cannot know it.
          gitBug = lib.makeOverridable (
            {
              # One Emacs package set supplies every dependency, so an
              # override of this argument moves all of them.
              emacs ? pkgs.emacs,
              emacsPackages ? emacs.pkgs,
              melpaBuild ? emacsPackages.melpaBuild,
              # Grammars for the check phase, also exported to the dev
              # shell so ad-hoc runs fontify bug bodies.
              markdownGrammars ? mkMarkdownGrammars pkgs,
              version ? "0.1.0",
            }:
            melpaBuild {
              pname = "git-bug";
              inherit version;

              # Elisp dependencies from the Package-Requires header.
              packageRequires = with emacsPackages; [ magit ];

              # `./.' is the repository root.  cleanSource drops VCS
              # metadata and editor backup files.
              src = lib.cleanSource ./.;

              # Rewrite the default executable name to the Nix store path
              # so the installed package works without anything on
              # `exec-path'.  Interpolating the derivation bakes the store
              # path in; `lib.getExe'' validates that the binary exists
              # inside it.
              postPatch = ''
                substituteInPlace git-bug.el \
                  --replace-fail 'git-bug-program "git-bug"' 'git-bug-program "${lib.getExe' pkgs.git-bug "git-bug"}"'
              '';

              # Byte-compilation warnings fail the build. Keep it on: it is
              # the cheapest lint the package will ever get.
              turnCompilationWarningToError = true;

              # The ERT suite byte-compiles with warnings as errors and then
              # drives the real git-bug binary inside throwaway repositories,
              # exercising the CLI, the parsing and the rendering together.
              checkPhase = ''
                runHook preCheck
                # The MELPA recipe stages only the root `*.el' files, so the
                # test tree must come back from the flake source.  Load it
                # from `test/' to keep the suite out of the package.
                cp -r ${./test} ./test
                # `package-initialize' (as elpa2nix does at install time) is
                # what puts the packageRequires dependencies on `load-path';
                # a plain batch Emacs cannot see them otherwise.
                emacs --batch -L . -L test \
                  --eval "(require 'package)" \
                  -f package-initialize \
                  --eval '(setq byte-compile-error-on-warn t)' \
                  -f batch-byte-compile test/*-test.el
                # Glob loader: a new test file needs no flake edit.  printf
                # repeats "-l %s" per match.  failglob makes an empty glob a
                # shell error, and the || guard reports it, because failglob
                # inside a command substitution aborts only the substitution.
                shopt -s failglob
                test_args=$(printf -- "-l %s " test/*-test.el) || {
                  echo 'no tests matched test/*-test.el' >&2
                  exit 1
                }
                shopt -u failglob
                # The unquoted $test_args is intentional: the words must
                # split into -l <file> pairs, safe because test file names
                # never contain spaces.
                emacs --batch -L . -L test \
                  --eval "(require 'package)" \
                  -f package-initialize \
                  --eval "(setq treesit-extra-load-path '(\"${markdownGrammars}\"))" \
                  $test_args \
                  -f ert-run-tests-batch-and-exit
                runHook postCheck
              '';

              doCheck = true;

              # The tests initialize temporary git repositories and run the
              # git-bug CLI against them.  The hook gives Emacs a private
              # writable home, so checks cannot leak state through $TMPDIR.
              nativeCheckInputs = [
                pkgs.git
                markdownGrammars
                pkgs.writableTmpDirAsHomeHook
              ];

              meta = {
                description = "Magit status sections for the git-bug bug tracker";
                longDescription = ''
                  Adds a collapsible "Bugs" section to Magit status buffers
                  listing the bugs of the git-bug distributed bug tracker,
                  which stores them in the repository's own refs/bugs/*
                  references.

                  The git-bug command-line tool is invoked behind the
                  scenes; when built with this flake its absolute store
                  path is baked in, so nothing has to be on exec-path.
                  On a bug heading, RET copies the short id and x flips
                  the open/closed status.
                '';
                # The license is declared in the file headers.
                license = lib.licenses.agpl3Plus;
                homepage = "https://github.com/nagy/emacs-git-bug";
                maintainers = with lib.maintainers; [ nagy ];
                platforms = lib.platforms.unix;
              };
            }
          ) { inherit version; };
        in
        {
          packages = {
            git-bug = gitBug;
            default = gitBug;
          };

          checks = {
            # melpaBuild already byte-compiles with warnings as errors and
            # `checkPhase' runs the ERT suite (against the real git-bug
            # binary), so building the package is the main check.
            default = gitBug;

            # checkdoc + package-lint: catch what byte-compilation cannot.
            lint =
              pkgs.runCommand "git-bug-lint"
                {
                  nativeBuildInputs = [
                    (pkgs.emacsPackages.emacsWithPackages (p: [ p.package-lint ]))
                    pkgs.writableTmpDirAsHomeHook
                  ];
                  # Lint the unpatched sources; the patched copy inside the
                  # built package differs only in one string literal.
                  src = gitBug.src;
                  meta.description = "checkdoc and package-lint for git-bug";
                }
                ''
                  # `src' is filtered, so copy the whole tree rather than
                  # listing files: `test/' is part of the lint surface too.
                  cp -r "$src"/. .
                  # package-lint assumes an online ELPA; offline it cannot
                  # resolve `magit', so register a stub package description
                  # via an advice on `package-initialize' (which resets
                  # `package-alist' on every call, wiping plain pushes).
                  # `package-lint-main-file' keeps the test files attached to
                  # the package they test instead of making each its own.
                  emacs --batch -l package-lint \
                    --eval '(setq package-lint-main-file "git-bug.el")' \
                    --eval '(advice-add (quote package-initialize) :after (lambda (&rest _) (push (cons (quote magit) (list (package-desc-create :name (quote magit) :version (quote (4 0 0)) :reqs nil :kind (quote single) :archive "stub" :summary "stub"))) package-alist)))' \
                    -f package-lint-batch-and-exit \
                    *.el test/*.el
                  # checkdoc always exits zero; gate on its output instead.
                  lint_log=$(emacs --batch -l checkdoc \
                    --eval '(setq checkdoc-arguments-in-order-flag t)' \
                    --eval '(mapc (lambda (f) (checkdoc-file f)) command-line-args-left)' \
                    *.el test/*.el 2>&1)
                  if [ -n "$lint_log" ]; then printf '%s\n' "$lint_log"; exit 1; fi
                  touch $out
                '';
          };

          # Dev shell mirroring what the package talks to at runtime: the
          # git-bug CLI, git and a real Emacs for interactive testing
          # (nix build; emacs -l result/share/emacs/site-lisp/elpa/git-bug-*/git-bug-autoloads.el).
          # MARKDOWN_GRAMMARS holds the tree-sitter grammars for markdown
          # fontification; add it to `treesit-extra-load-path'.
          devShells.default = pkgs.mkShell {
            packages = [
              # `emacsWithPackages' sets EMACSLOADPATH, so `emacs -Q'
              # can load Magit and its dependencies for ad-hoc tests.
              (pkgs.emacsPackages.emacsWithPackages (p: [ p.magit ]))
              pkgs.git
              pkgs.git-bug
            ];
            MARKDOWN_GRAMMARS = mkMarkdownGrammars pkgs;
          };

          # `nix fmt' formats the flake via treefmt, never the formatters
          # standalone.
          formatter = treefmt-nix.lib.mkWrapper pkgs {
            projectRootFile = "flake.nix";
            programs.nixfmt.enable = true;
          };
        };
    };
}
