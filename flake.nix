{
  description = "neotest adapter for Bazel monorepos";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        python = pkgs.python312.withPackages (ps: [ ps.pytest ]);

        # We depend on the standalone tree-sitter PARSERS, not on the
        # nvim-treesitter plugin: neotest uses the built-in vim.treesitter and
        # neotest-python bundles its own queries, so nvim-treesitter's Lua is
        # not needed.  Crucially, with nvim-treesitter absent, neotest's parsing
        # subprocess never tries to require("nvim-treesitter") in the child (that
        # call is pcall-guarded on whether it's installed), sidestepping the
        # rtp-split failure entirely.  See the nixpkgs Neovim docs on treesitter
        # grammars as plugin dependencies.
        plugin-deps = with pkgs.vimPlugins; [
          plenary-nvim
          nvim-nio
          neotest
          neotest-python
          nvim-treesitter-parsers.python
          nvim-treesitter-parsers.starlark
        ];

        # Provide the runtime plugins as `buildInputs`, not `dependencies`.
        # buildVimPlugin's require-check hook adds buildInputs to the rtp, so
        # the build-time `require()` of our modules (which pull in neotest,
        # neotest-python, nio, plenary) still passes -- but buildInputs are NOT
        # propagated to consumers.  `dependencies` would be: nixpkgs' pluginToDrv
        # walks the transitive closure of a plugin's `dependencies` and resolves
        # any string entry (e.g. a rockspec dep like "nvim-nio") against the
        # consumer's pkgs.vimPlugins, which breaks nixvim/home-manager setups.
        # A consumer supplies the neotest stack itself (see README Requirements).
        neotest-bazel-modular = pkgs.vimUtils.buildVimPlugin {
          pname = "neotest-bazel-modular";
          version = "0-unstable";
          src = self;
          buildInputs = plugin-deps;
        };

        # The test/check Neovim only needs the dependencies: the spec suite
        # loads the adapter from source via tests/minimal_init.lua (which
        # prepends the source tree to the rtp), so the built plugin package
        # would be redundant here.
        neovim = pkgs.neovim.override {
          configure.packages.test-deps.start = plugin-deps;
        };

        # The demo bundles the built plugin package too, because its customRC
        # does a bare require("neotest-bazel-modular") with no source prepend.
        demo-neovim = pkgs.neovim.override {
          configure = {
            packages.demo.start = plugin-deps ++ [ neotest-bazel-modular ];
            customRC = ''
              lua << EOF
              vim.api.nvim_create_autocmd("VimEnter", {
                once = true,
                callback = function()
                  require("neotest").setup({
                    adapters = { require("neotest-bazel-modular") },
                  })
                  vim.keymap.set("n", "<leader>tn", function()
                    require("neotest").run.run()
                  end, { desc = "Run nearest test" })
                  vim.keymap.set("n", "<leader>tf", function()
                    require("neotest").run.run(vim.fn.expand("%"))
                  end, { desc = "Run file" })
                  vim.keymap.set("n", "<leader>ts", function()
                    require("neotest").summary.toggle()
                  end, { desc = "Toggle summary" })
                  vim.keymap.set("n", "<leader>to", function()
                    require("neotest").output_panel.toggle()
                  end, { desc = "Toggle output" })
                end,
              })
              EOF
            '';
          };
        };

        # All Bazel use inside the demo goes through this wrapper, which pins a
        # demo-specific output_user_root.  The default output base is a function
        # only of the workspace path, so a `bazel` run from a plain shell and one
        # run inside this FHS chroot would otherwise share -- and reuse -- the
        # same server.  A server started outside the chroot has no
        # /usr/bin/python3, so its test actions fail.  Pinning a dedicated root
        # guarantees nothing but the demo ever touches this output base, so its
        # server is always born inside the namespace where /usr/bin/python3
        # exists, on this run and every future one.
        bazel-demo = pkgs.writeShellScriptBin "bazel" ''
          exec ${pkgs.bazel}/bin/bazel \
            --output_user_root="''${XDG_CACHE_HOME:-$HOME/.cache}/neotest-bazel-demo" \
            "$@"
        '';

      in
      {
        packages.default = neotest-bazel-modular;

        # neovim launched inside an FHS environment, so the bazel processes it
        # spawns find /usr/bin/python3 at the path the unittest runner's stub
        # expects.  runScript is nvim itself: `nix run .#demo -- some_test.py`
        # enters the chroot and opens the file. Any args pass through to nvim.
        packages.demo = pkgs.buildFHSEnv {
          name = "neotest-bazel-demo";
          targetPkgs =
            _:
            [ demo-neovim ]
            ++ (with pkgs; [
              python
              bazel-demo
              bash
              coreutils
              which
              gnutar
              gzip
              zip
              unzip
            ]);
          runScript = "nvim";
          profile = ''
            export PYTHON_BIN_PATH="${python}/bin/python3"
            export PYTHON_LIB_PATH="${python}/lib/python3.12"
            export XDG_CACHE_HOME="''${XDG_CACHE_HOME:-$HOME/.cache}"
            mkdir -p "$XDG_CACHE_HOME/neotest-bazel-demo"
          '';
        };

        # Run the in-process spec suite headlessly against the test Neovim
        # (the adapter is loaded from source by tests/minimal_init.lua).
        # tests/run.lua calls `cquit 1` on any failure, so a non-zero nvim exit
        # fails the check; otherwise we touch $out to mark success.
        checks.default =
          pkgs.runCommand "neotest-bazel-modular-tests" { nativeBuildInputs = [ neovim ]; }
            ''
              cp -r ${self} src
              chmod -R u+w src
              cd src
              export HOME="$TMPDIR"
              nvim --headless -i NONE -u tests/minimal_init.lua \
                -c "luafile tests/run.lua" -c "qa!"
              touch "$out"
            '';

        devShells.default = pkgs.mkShell {
          packages = [
            pkgs.gnumake
            neovim
          ];
        };
      }
    );
}
