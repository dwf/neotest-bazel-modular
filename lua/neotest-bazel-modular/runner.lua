-- Shared `bazel test` run-spec construction and results post-processing.
--
-- Everything here is language-agnostic: a language sub-adapter supplies its own
-- `test_filter` function (how a position maps to a runner filter string) and a
-- results collector, and reuses build_spec/results unchanged.

local resolve = require("neotest-bazel-modular.resolve")

local M = {}

-- Build a neotest RunSpec that runs `bazel test` for args.tree's position.
--
-- opts fields:
--   bazel            (string)   bazel executable
--   target_resolver  (string)   "treesitter" (default) or "query"
--   filter_arg       (string)   format string, %s replaced with the filter
--   args             (string[]) extra flags appended to every invocation
--   testlogs_symlink (string)   bazel-testlogs symlink name
--   test_filter      (function) function(args) -> string|nil, the language's
--                               position -> runner filter mapping
--
-- Returns the RunSpec, or nil when no Bazel target can be resolved for the file.
function M.build_spec(args, root, opts)
  local position = args.tree:data()
  local filter = opts.test_filter and opts.test_filter(args) or nil

  local target
  if opts.target_resolver == "query" then
    target = resolve.query(position.path, root, opts.bazel)
  else
    target = resolve.treesitter(position.path, root)
  end
  if not target then
    return nil
  end

  local flags = {}
  if filter then
    flags[#flags + 1] = string.format(opts.filter_arg, vim.fn.shellescape(filter))
  end
  for _, flag in ipairs(opts.args or {}) do
    flags[#flags + 1] = vim.fn.shellescape(flag)
  end

  local cmd = string.format("%s test %s %s", opts.bazel, vim.fn.shellescape(target), table.concat(flags, " "))

  return {
    command = { "sh", "-c", cmd },
    cwd = root,
    context = {
      testlogs_symlink = opts.testlogs_symlink,
      position_id = position.id,
      root = root,
      target = target,
    },
  }
end

-- Run `collect` and apply the generic failure fallbacks neotest needs.
function M.results(spec, result, tree, collect)
  local r = collect(spec, result, tree)

  -- Collector returned nil: no results were produced.  The command failed
  -- before writing any output (sandbox error, etc.).  Report the running
  -- position as failed.
  if not r then
    return { [spec.context.position_id] = { status = "failed", output = result.output } }
  end

  -- If the process exited non-zero but no failures appear in the collected
  -- results, the binary likely crashed (import error, segfault) before any
  -- individual test ran.  Mark the running position as failed so the user sees
  -- something is wrong rather than a spurious all-green report.
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

return M
