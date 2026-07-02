# neotest-bazel-modular

A [neotest](https://github.com/nvim-neotest/neotest) adapter for running **Bazel** tests from Neovim: it discovers test files, resolves each to its Bazel target, runs `bazel test`, and maps the JUnit results back to individual tests in the neotest UI.

Only **Python** is supported today, via a built-in sub-adapter. The adapter is built around a pluggable per-language router, so support for other languages can be added — or the Python behaviour overridden method-by-method — without touching the core.

> **A note on Nix.** The author is a heavy [Nix](https://nixos.org/)/NixOS user,
> so this repository ships a `flake.nix` and the docs lean on it for examples.
> Nix is **not** required to use the plugin or to run its tests — install it
> with any Neovim plugin manager (see [Installation](#installation)) and run the
> suite with a plain `make test` (see [Running the tests](#running-the-tests)).
> The Nix flake is provided purely as a convenience for those who want it.

## Features

- Keeps neotest's discovery root separate from the Bazel workspace root — point `discovery_root` at your working "neighbourhood" (e.g. the nearest package) so neotest doesn't crawl an entire huge monorepo. It defaults to the workspace root; both roots are overridable (see [Options](#options))
- Prunes Bazel output symlinks (`bazel-bin`, `bazel-out`, `bazel-testlogs`, …) and common large directories so the neotest directory walker stays fast
- Supports resolving the Bazel target for a test file two ways — parsing the nearest `BUILD.bazel`/`BUILD` with tree-sitter (no subprocess), or `bazel query` (handles `glob()`); see [How Bazel targets are resolved](#how-bazel-targets-are-resolved)
- Bundles several pluggable results collectors, including one for [`absl.testing`](https://abseil.io/docs/python/guides/testing) that maps parameterized cases and subtests back to their source method
- Per-language sub-adapters are configurable: override individual methods or replace the entire factory

### Python support

The provided Python sub-adapter delegates test discovery to
[neotest-python](https://github.com/nvim-neotest/neotest-python) (which must
be installed), borrowing its `is_test_file` predicate and its pytest-style
tree-sitter query.  This means discovery behaviour matches neotest-python
exactly:

| What | Discovered as |
|---|---|
| Top-level `test_*` functions | test |
| Any class | namespace |
| `test_*` methods inside a class | test (under the class namespace) |
| Decorated `test_*` functions/methods (`@skip`, `@parametrize`, …) | test |

By default, results are read from the JUnit XML Bazel writes to `bazel-testlogs`
using the [`absl.testing`](https://abseil.io/docs/python/guides/testing)
collector, which maps parameterized cases and subtests back to their source
method (and degrades to plain exact-name matching for ordinary tests).  Other
collectors — a simplified generic JUnit reader and a `unittest` text-output
parser — are available too; see
[Choosing a results collector](#choosing-a-results-collector) below.

## Requirements

- Neovim ≥ 0.9
- [neotest](https://github.com/nvim-neotest/neotest)
- [nvim-nio](https://github.com/nvim-neotest/nvim-nio)
- [plenary.nvim](https://github.com/nvim-lua/plenary.nvim)
- The `python` and `starlark` tree-sitter parsers available to Neovim (the adapter uses the built-in `vim.treesitter`, so the `nvim-treesitter` plugin itself is not required — though `:TSInstall python starlark` is the easy way to install the parsers; under Nix, depend on `vimPlugins.nvim-treesitter-parsers.{python,starlark}`)
- [neotest-python](https://github.com/nvim-neotest/neotest-python) — required by the built-in Python sub-adapter for `is_test_file` and tree-sitter query delegation
- A working `bazel` (or `bazelisk`) binary on `$PATH`

## Installation

### lazy.nvim

```lua
{
  "dwf/neotest-bazel-modular",
  dependencies = {
    "nvim-neotest/neotest",
    "nvim-neotest/nvim-nio",
    "nvim-lua/plenary.nvim",
    "nvim-treesitter/nvim-treesitter",
    "nvim-neotest/neotest-python",
  },
}
```

### Nix / NixVim

The repository exposes a `packages.default` (the plugin itself, built with
`buildVimPlugin`), a `devShells.default` for running the test suite, and a
`packages.demo` that launches a fully configured Neovim for trying the adapter
against a real Bazel workspace.

**Dev shell** — Neovim with all test dependencies; used for `make test`:

```sh
nix develop
make test
```

**Demo** — Neovim with the adapter bundled in and neotest pre-configured,
launched inside an FHS environment so the Bazel test runners it spawns find
`/usr/bin/python3`. Pass any files/args through to `nvim` after `--`:

```sh
nix run .#demo -- path/to/test_something.py
```

The demo pins its own Bazel `output_user_root`, so its Bazel server never
collides with one started by a plain-shell `bazel` (which would live outside
the FHS namespace and fail to locate the Python interpreter).

The demo uses the adapter's default Python configuration, which reads results
with the `absl.testing` JUnit collector (`results/xml_python_absl.lua`). For
targets that run the plain `unittest` runner without JUnit XML output, configure
the `python_unittest` collector (and `filter_arg = "--test_arg=%s"`) instead — see
[Choosing a results collector](#choosing-a-results-collector).

Keymaps available in the demo:

| Key | Action |
|---|---|
| `<leader>tn` | Run nearest test |
| `<leader>tf` | Run file |
| `<leader>ts` | Toggle neotest summary panel |
| `<leader>to` | Toggle output panel |

To consume the adapter in your own Nix config, add `packages.default` (or the source) as a plugin. It does **not** declare its runtime plugins as `dependencies`, so add the [Requirements](#requirements) — neotest, nvim-nio, plenary.nvim, neotest-python, and the `python`/`starlark` tree-sitter parsers — to your own plugin set alongside it (with nixvim/home-manager you almost certainly already have the neotest stack). Dependencies are intentionally not propagated: nixpkgs resolves a plugin's transitive `dependencies` against your `pkgs.vimPlugins`, which breaks on the neotest rockspec's string deps.

## Setup

Pass the adapter to neotest in your config. Passing it directly, as below, uses
the defaults (which work for a standard Bazel + Python setup):

```lua
require("neotest").setup({
  adapters = {
    require("neotest-bazel-modular"),
  },
})
```

To configure it, call it with an options table instead —
`require("neotest-bazel-modular")({ … })` — see [Options](#options). Everything
is optional.

### Options

```lua
require("neotest-bazel-modular")({
  -- The root neotest scans for test files (i.e. the adapter's `root`).  In a
  -- large monorepo the Bazel workspace root can be enormous and scanning all of
  -- it is far too slow, so scope discovery to a subtree here.  Receives the
  -- directory of the file being tested; returns an absolute path or nil.
  -- Default: the Bazel workspace root.  Example — scope to the nearest package:
  discovery_root = function(dir)
    return require("neotest.lib").files.match_root_pattern("BUILD.bazel", "BUILD")(dir)
  end,

  -- The Bazel workspace root, used to set the `bazel test` cwd, compute the
  -- //pkg:target label, and locate bazel-testlogs.  Override only if your
  -- workspace marker isn't one of the defaults.  Receives a directory; returns
  -- an absolute path or nil.
  -- Default: walk up looking for MODULE.bazel / WORKSPACE.bazel / WORKSPACE.
  bazel_workspace_root = function(dir)
    return require("neotest.lib").files.match_root_pattern("MODULE.bazel")(dir)
  end,

  -- Bazel executable. Useful if you use e.g. bazelisk or a wrapper script.
  bazel_binary = "bazelisk",

  -- How the Bazel target label is resolved for each test file.
  -- See "How Bazel targets are resolved" below for a full explanation.
  --   "treesitter" (default) — parse the nearest BUILD.bazel/BUILD with
  --                            treesitter; no subprocess, no daemon needed,
  --                            but does not handle glob() in srcs.
  --   "query"          — run `bazel query attr(srcs,...)` synchronously;
  --                            handles glob(), requires a running Bazel daemon.
  -- Can be overridden per-language inside the language config table.
  target_resolver = "treesitter",

  -- Directory names excluded from neotest's file scan.  Entries ending with
  -- "*" are prefix-matched; all others are matched exactly against the
  -- directory name (not its path).  Supplying this key replaces the defaults
  -- entirely, so include anything from the defaults you still want.
  -- Defaults: { ".git", "node_modules", "vendor", "bazel-*" }
  --   ".git"         — version-control metadata
  --   "node_modules" — JS/TS dependency trees
  --   "vendor"       — vendored dependencies (Go, Ruby, …)
  --   "bazel-*"      — Bazel output symlinks (bazel-bin, bazel-out, …)
  ignore_dirs = { ".git", "node_modules", "vendor", "bazel-*", "_build" },

  -- Name of the bazel-testlogs convenience symlink under the workspace root,
  -- where the JUnit XML results collector reads test.xml from.  Global only.
  -- Default: "bazel-testlogs".
  testlogs_symlink = "bazel-testlogs",

  -- Per-language configuration.  Each key accepts either a config table
  -- (merged with defaults) or a factory function (replaces the built-in
  -- sub-adapter entirely).
  python = {
    -- Extra flags appended to every `bazel test` invocation.
    args = { "--config=ci", "--test_timeout=120" },

    -- How the test filter is passed to the runner.  %s is replaced with the
    -- escaped filter string.  The default uses Bazel's standard mechanism,
    -- which sets TESTBRIDGE_TEST_ONLY in the test environment.  Switch to
    -- "--test_arg=%s" for runners that read the filter from sys.argv[1]
    -- (e.g. Python's built-in unittest runner via rules_python).
    filter_arg = "--test_filter=%s",

    -- Override the target resolver for Python only (overrides the top-level
    -- target_resolver setting).
    target_resolver = "query",

    -- Any function-valued key replaces the corresponding method on the
    -- sub-adapter.  The overridable methods and their signatures are:
    --
    --   is_test_file(path) -> boolean
    --       Whether `path` is a test file neotest should consider.
    --   discover_positions(path) -> neotest.Tree
    --       Parse `path` into a tree of namespace/test positions.
    --   build_spec(args, root) -> neotest.RunSpec | nil
    --       Build the run spec for `args.tree`'s position within workspace
    --       `root`.  Return nil to skip (neotest falls back to sub-positions).
    --   results(spec, result, tree) -> table<position_id, { status }>
    --       Map the finished run back to per-position statuses.
    --
    -- (results_collector above is the recommended hook for customising result
    -- parsing; override results() only if you need to change control flow.)
    is_test_file = function(path)
      return path:match("_spec%.py$") ~= nil
    end,
  },
})
```

#### Choosing a results collector

The Python sub-adapter's results collector is configurable.  A collector is any
function `collect(spec, result, tree) -> table<position_id, { status }> | nil`,
so you can plug in your own.

The **default**, `results/xml_python_absl.lua`, reads the JUnit XML Bazel writes
to `bazel-testlogs` and handles
[`absl.testing`](https://abseil.io/docs/python/guides/testing) suites correctly:
parameterized cases (`@parameterized.parameters` / `named_parameters`) and
`self.subTest` cases are each mapped back to their decorated source method and
aggregated, so any failing case or subtest fails the parent, with a per-case
diagnostic (and the source line, where the traceback gives one).  Named
parameterizations are resolved by parsing the decorator in the source, which
handles the otherwise-ambiguous cases.

`results/xml.lua` is a **simplified, language-agnostic** JUnit reader.  Nothing
references it by default (the Python default is the absl collector above) and
nothing in it is Python-specific — it's a standalone, opt-in collector that also
serves as the clearest starting template for a collector for any language that
emits standard JUnit XML.  It maps each `<testcase classname="…" name="…">` to a
position by class + method name (no parameterization handling) and surfaces
`<failure>`/`<error>` messages as diagnostics:

```lua
require("neotest-bazel-modular")({
  python = {
    results_collector = require("neotest-bazel-modular.results.xml").collect,
  },
})
```

`results/python_unittest.lua` is another worked example: it parses `FAIL:` /
`ERROR:` lines from the plain `unittest` runner's text output instead of reading
XML — for setups without JUnit XML.

```lua
require("neotest-bazel-modular")({
  python = {
    results_collector = require("neotest-bazel-modular.results.python_unittest").collect,
  },
})
```

Both `results/xml.lua` and `results/xml_python_absl.lua` share the JUnit
plumbing in `results/junit.lua` (testlogs resolution, shard walking, `<testcase>`
iteration), so a new XML-based collector only has to implement the mapping.

#### Replacing a sub-adapter factory

If the config-table overrides are not flexible enough you can supply a full factory function. It receives the merged base config (`{ bazel_binary = "…", target_resolver = "…" }`) and must return a table with `is_test_file`, `discover_positions`, `build_spec`, and `results` methods.

```lua
require("neotest-bazel-modular")({
  python = require("my-custom-python-adapter"),
})
```

## How Bazel targets are resolved

Before running a test the adapter must map the test file's path to a Bazel
target label (e.g. `//tests/unit:test_math_helpers`).  Two strategies are
available, selected by the `target_resolver` option.

### `"treesitter"` (default)

Walks up from the test file's directory toward the workspace root, checking
each directory for `BUILD.bazel` first (preferred over `BUILD` per
[Bazel's own documentation](https://bazel.build/concepts/build-files)), then
`BUILD`.  The first file found is parsed with the Starlark treesitter grammar;
the adapter scans every rule call whose literal `srcs` (a list or a bare
string) contains the test file's path relative to the BUILD file's directory.
Among those matches it prefers a rule whose kind ends in `_test` (`py_test`,
`cc_test`, …) — falling back to the first match of any kind — and returns that
rule's `name`.

**Advantages:** pure file I/O + treesitter, no subprocess spawned, no Bazel
daemon required, resolves immediately.

**Limitations:**

- Only literal `srcs` are understood (a list or a single string).  If your
  BUILD file uses `glob()` or stores file paths in a variable, the adapter will
  not find a match and `build_spec` returns nil (neotest falls back to running
  sub-positions individually).  Switch to `"query"` if your BUILD files rely on
  `glob()`.
- The matched call's `name` is assumed to be the runnable target label.  This
  holds for plain rules and for macros that create a primary target named
  exactly `name`, but not for macros that derive target names from it (e.g.
  `name .. "_test"`).  Use `"query"` for those.
- Rule kind is matched only heuristically: among the rules listing the file,
  one whose kind ends in `_test` (`py_test`, `cc_test`, …) is preferred, so a
  file also listed in a `filegroup` or library normally resolves to the test
  rule.  But a test rule whose kind does not end in `_test` is only a fallback,
  and if the *sole* match is a non-test rule its label is still returned.  The
  `"query"` resolver scopes to `tests(//...)` and has neither caveat.

### `"query"`

Runs the following synchronously inside `build_spec` before issuing the test
command:

```sh
bazel query "attr(srcs, '//pkg:file\.py', tests(//...))" 2>/dev/null | head -1
```

The universe is scoped to `tests(//...)` rather than `//...`, so the query only
ever returns runnable test targets — a file also listed in a `filegroup` or
library can't resolve to a non-test target that `bazel test` would reject.
`tests()` additionally expands `test_suite` targets to their constituent tests.

**Advantages:** handles `glob()`, variable references, and any other expression
Bazel evaluates; resolves a target even when the file appears under multiple
packages.

**Trade-off:** requires a running Bazel daemon; adds query latency before the
test command is issued (typically <1 s with a warm daemon, several seconds on a
cold start).  When multiple targets match, `head -1` picks one arbitrarily.

## Running the tests

For the quick inner loop, run the suite against the dev shell's Neovim:

```sh
nix develop   # enter the dev shell (provides neovim + all dependencies)
make test
```

`make test` just runs `nvim --headless` against the spec runner, so you don't
need Nix to use it: if you already have a Neovim with the runtime dependencies
on its runtimepath (plenary.nvim, neotest, nvim-nio, neotest-python, and
nvim-treesitter with the `python` and `starlark` parsers), run `make test`
directly. The `make test-nix` target wraps the same command in `nix develop`
so Nix supplies Neovim and every dependency for you.

To run the same suite hermetically in the Nix sandbox — what CI should gate on
— use the flake check:

```sh
nix flake check          # runs checks.default (and evaluates the rest)
# or just the test check:
nix build .#checks.$(nix eval --raw --impure --expr builtins.currentSystem).default
```

`checks.default` runs the bundled Neovim headlessly against a copy of the
source; `tests/run.lua` exits non-zero (`cquit 1`) on any failure, so a
regression fails the build.

The test suite uses a minimal in-process runner (`tests/run.lua`) rather than plenary's child-spawning harness, which deadlocks when child nvim processes load neotest outside an active event loop.

## Limitations

- Only Python is supported today; the router pattern is designed to make adding further languages straightforward
- Test filtering uses `--test_filter=%s` by default, which sets `TESTBRIDGE_TEST_ONLY` in the test environment — Bazel's standard mechanism, honoured by runners that read that variable (e.g. a pytest setup wired to consume it).  Note that `rules_python`'s plain `unittest` runner does **not** read `TESTBRIDGE_TEST_ONLY`; its bootstrap simply forwards arguments to the test as `sys.argv`, so to filter a single test you must set `filter_arg = "--test_arg=%s"` (which passes the filter that `unittest` itself parses)
- `"treesitter"` resolution does not handle `glob()` or non-literal `srcs` expressions, and assumes the matched rule's `name` is the runnable target (so macros that derive target names from `name` are not resolved); use `target_resolver = "query"` for those BUILD files
- `"query"` resolution picks one target arbitrarily (via `head -1`) when a file appears in multiple targets

## Acknowledgements

- The [neotest](https://github.com/nvim-neotest/neotest) authors and contributors, whose adapter framework this plugin builds on (and whose [neotest-python](https://github.com/nvim-neotest/neotest-python) the Python sub-adapter leverages).
- [Claude](https://www.anthropic.com/claude) (Anthropic), which wrote the majority of the code under the author's watchful direction.
- [Gemini](https://deepmind.google/technologies/gemini/) (Google), which helped the author quickly understand the neotest adapter API and craft a plan for the plugin.
