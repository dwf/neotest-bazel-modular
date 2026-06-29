local lib = require("neotest.lib")
local base = require("neotest-python.base")
local xml_results = require("neotest-bazel-modular.results.xml")
local resolve = require("neotest-bazel-modular.resolve")

-- Delegate the treesitter query to neotest-python.  With runner="pytest" and
-- no config overrides this returns the standard pytest query (all classes as
-- namespaces, all ^test functions/methods including decorated ones).
-- Exposed as _QUERY so tests can drive vim.treesitter directly without going
-- through the async parse_positions path.
local _QUERY = base.treesitter_queries("pytest", {}, nil)

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
  local bazel = config.bazel_binary or "bazel"
  local extra_args = config.args or {}
  local filter_arg = config.filter_arg or "--test_filter=%s"
  local testlogs_symlink = config.testlogs_symlink or "bazel-testlogs"
  local target_resolver = config.target_resolver or "treesitter"
  -- results_collector must have the signature:
  --   collect(spec, result, tree) -> table<string, {status}> | nil
  local collect = config.results_collector or xml_results.collect

  local M = {}

  M.is_test_file = base.is_test_file

  function M.discover_positions(path)
    return lib.treesitter.parse_positions(path, _QUERY, {
      nested_namespaces = true,
      require_namespaces = false,
    })
  end

  function M.build_spec(args, root)
    local position = args.tree:data()
    local filter = test_filter_for(args)

    local target
    if target_resolver == "query" then
      target = resolve.query(position.path, root, bazel)
    else
      target = resolve.treesitter(position.path, root)
    end
    if not target then
      return nil
    end

    local flags = {}
    if filter then
      flags[#flags + 1] = string.format(filter_arg, vim.fn.shellescape(filter))
    end
    for _, flag in ipairs(extra_args) do
      flags[#flags + 1] = vim.fn.shellescape(flag)
    end

    local cmd = string.format("%s test %s %s", bazel, vim.fn.shellescape(target), table.concat(flags, " "))

    return {
      command = { "sh", "-c", cmd },
      cwd = root,
      context = {
        testlogs_symlink = testlogs_symlink,
        position_id = position.id,
        root = root,
        target = target,
      },
    }
  end

  function M.results(spec, result, tree)
    local r = collect(spec, result, tree)

    -- Collector returned nil: no XML output was produced.  The command
    -- failed before writing any results (sandbox error, etc.).  Report the
    -- running position as failed.
    if not r then
      return { [spec.context.position_id] = { status = "failed", output = result.output } }
    end

    -- If the process exited non-zero but no failures appear in the collected
    -- results, the binary likely crashed (import error, segfault) before any
    -- individual test ran.  Mark the running position as failed so the user
    -- sees something is wrong rather than a spurious all-green report.
    if result.code ~= 0 then
      for _, v in pairs(r) do
        if v.status == "failed" then
          return r
        end
      end
      r[spec.context.position_id] = { status = "failed", output = result.output }
    end

    return r
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
