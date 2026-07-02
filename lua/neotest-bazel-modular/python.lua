local lib = require("neotest.lib")
local base = require("neotest-python.base")
local absl_results = require("neotest-bazel-modular.results.xml_python_absl")
local runner = require("neotest-bazel-modular.runner")

-- Delegate the treesitter query to neotest-python.  With runner="pytest" and
-- no config overrides this returns the standard pytest query (all classes as
-- namespaces, all ^test functions/methods including decorated ones).
-- Exposed as _QUERY so tests can drive vim.treesitter directly without going
-- through the async parse_positions path.
local _QUERY = base.treesitter_queries("pytest", {}, nil)

-- The python-specific half of build_spec: map a position to a pytest/unittest
-- filter ("Class.method", "method", or "Class").  Everything else about the
-- run spec is shared (see runner.lua).
local function test_filter_for(args)
  local position = args.tree:data()
  if position.type == "test" then
    local parent = args.tree:parent()
    if parent and parent:data().type == "namespace" then
      return parent:data().name .. "." .. position.name
    end
    return position.name
  elseif position.type == "namespace" then
    return position.name
  end
  return nil
end

local function factory(config)
  config = config or {}
  local opts = {
    bazel = config.bazel_binary or "bazel",
    args = config.args or {},
    filter_arg = config.filter_arg or "--test_filter=%s",
    testlogs_symlink = config.testlogs_symlink or "bazel-testlogs",
    target_resolver = config.target_resolver or "treesitter",
    test_filter = test_filter_for,
  }
  -- results_collector must have the signature:
  --   collect(spec, result, tree) -> table<position_id, {status}> | nil
  -- Defaults to the absl.testing collector: it maps parameterized/subtest
  -- <testcase>s back to their source method and aggregates, degrading to plain
  -- exact-name matching for non-parameterized tests.
  local collect = config.results_collector or absl_results.collect

  local M = {}

  M.is_test_file = base.is_test_file

  function M.discover_positions(path)
    return lib.treesitter.parse_positions(path, _QUERY, {
      nested_namespaces = true,
      require_namespaces = false,
    })
  end

  function M.build_spec(args, root)
    return runner.build_spec(args, root, opts)
  end

  function M.results(spec, result, tree)
    return runner.results(spec, result, tree, collect)
  end

  -- Function-valued config entries replace adapter methods directly, allowing
  -- callers to swap out is_test_file, discover_positions, build_spec, or
  -- results without reimplementing the whole factory.
  for k, v in pairs(config) do
    if type(v) == "function" then
      M[k] = v
    end
  end

  return M
end

-- Return a callable table so callers invoke it like a function while tests
-- can also read _QUERY directly to drive vim.treesitter without going through
-- neotest's async layer (lib.treesitter.parse_positions is a nio async
-- function that deadlocks when called outside an active event loop).
return setmetatable({ _QUERY = _QUERY }, {
  __call = function(_, ...)
    return factory(...)
  end,
})
