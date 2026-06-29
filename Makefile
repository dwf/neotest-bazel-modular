# Run the spec suite headlessly.
#
# This invokes whatever `nvim` is on your PATH, so it works both inside a
# `nix develop` shell (which supplies a Neovim with every dependency bundled)
# and with a system Neovim -- provided that Neovim already has the runtime
# dependencies on its runtimepath: plenary.nvim, neotest, nvim-nio,
# neotest-python, and nvim-treesitter with the python and starlark parsers.
test:
	nvim --headless -i NONE -u tests/minimal_init.lua -c "luafile tests/run.lua" -c "qa!" 2>&1

# Same suite, but let Nix provide Neovim and all dependencies.
test-nix:
	nix develop --command $(MAKE) test
