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
    # e.g. "20260922133522".
    let
      lastModifiedDate = inputs.self.sourceInfo.lastModifiedDate;
      commitDate = "${builtins.substring 0 4 lastModifiedDate}-${
        builtins.substring 4 2 lastModifiedDate
      }-${builtins.substring 6 2 lastModifiedDate}";
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
          inherit (pkgs.emacsPackages) melpaBuild;
          # Tree-sitter grammars for the markdown fontification of bug
          # bodies, renamed to the "libtree-sitter-<lang>.so" names
          # treesit loads: the grammar packages ship the shared object
          # as a bare "parser" file.
          markdownGrammars = pkgs.runCommand "tree-sitter-markdown-grammars" { } ''
            mkdir -p $out
            ln -s ${pkgs.tree-sitter-grammars.tree-sitter-markdown}/parser \
              $out/libtree-sitter-markdown.so
            ln -s ${pkgs.tree-sitter-grammars.tree-sitter-markdown-inline}/parser \
              $out/libtree-sitter-markdown-inline.so
          '';
        in
        {
          packages.git-bug = melpaBuild {
            pname = "git-bug";
            # Nix rejects versions Nixpkgs cannot parse. Convention for
            # unreleased packages: <upstream-version>-unstable-<YYYY-MM-DD>,
            # where the date is the last commit touching the source. Derived
            # from the flake's source info, so it never goes stale.
            version = "0.1.0-unstable-${commitDate}";

            src = lib.cleanSource ./.;

            # Elisp dependencies from the Package-Requires header.
            packageRequires = with pkgs.emacsPackages; [ magit ];

            # Rewrite the default executable name to the Nix store path so
            # the installed package works without anything on `exec-path'.
            # Interpolating the derivation bakes the store path in;
            # `lib.getExe'' validates that the binary exists inside it.
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
              export HOME=$TMPDIR
              # `package-initialize' (as elpa2nix does at install time) is
              # what puts the packageRequires dependencies on `load-path';
              # a plain batch Emacs cannot see them otherwise.
              emacs --batch -L . \
                --eval "(require 'package)" \
                -f package-initialize \
                --eval '(setq byte-compile-error-on-warn t)' \
                -f batch-byte-compile git-bug-tests.el
              emacs --batch -L . \
                --eval "(require 'package)" \
                -f package-initialize \
                --eval "(setq treesit-extra-load-path '(\"${markdownGrammars}\"))" \
                -l git-bug-tests.elc \
                -f ert-run-tests-batch-and-exit
              runHook postCheck
            '';

            doCheck = true;

            # The tests initialize temporary git repositories and run the
            # git-bug CLI against them.
            nativeCheckInputs = [
              pkgs.git
              markdownGrammars
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
          };

          packages.default = config.packages.git-bug;

          checks = {
            # melpaBuild already byte-compiles with warnings as errors and
            # `checkPhase' runs the ERT suite (against the real git-bug
            # binary), so building the package is the main check.
            default = config.packages.git-bug;

            # checkdoc + package-lint: catch what byte-compilation cannot.
            lint =
              pkgs.runCommand "git-bug-lint"
                {
                  nativeBuildInputs = [
                    (pkgs.emacsPackages.emacsWithPackages (p: [ p.package-lint ]))
                  ];
                  # Lint the unpatched sources; the patched copy inside the
                  # built package differs only in one string literal.
                  src = config.packages.git-bug.src;
                  meta.description = "checkdoc and package-lint for git-bug";
                }
                ''
                  export HOME=$TMPDIR
                  cp "$src"/git-bug.el "$src"/git-bug-tests.el .
                  # package-lint assumes an online ELPA; offline it cannot
                  # resolve `magit', so register a stub package description
                  # via an advice on `package-initialize' (which resets
                  # `package-alist' on every call, wiping plain pushes).
                  emacs --batch -l package-lint \
                    --eval '(advice-add (quote package-initialize) :after (lambda (&rest _) (push (cons (quote magit) (list (package-desc-create :name (quote magit) :version (quote (4 0 0)) :reqs nil :kind (quote single) :archive "stub" :summary "stub"))) package-alist)))' \
                    -f package-lint-batch-and-exit git-bug.el
                  # checkdoc always exits zero; gate on its output instead.
                  lint_log=$(emacs --batch -l checkdoc \
                    --eval '(progn (checkdoc-file "git-bug.el") (checkdoc-file "git-bug-tests.el"))' 2>&1)
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
            MARKDOWN_GRAMMARS = markdownGrammars;
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
