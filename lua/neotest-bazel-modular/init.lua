local lib = require("neotest.lib")

-- This adapter is intentionally a process-wide singleton: configuration lives
-- in module-level state (`registry`, `ignore_dirs`, `Adapter.root`) that __call
-- replaces in place, and the module returns that one Adapter table.  neotest
-- identifies adapters by `name`, and a Bazel workspace wants a single config,
-- so one configured instance per session is the intended model.  Calling the
-- module a second time reconfigures that instance rather than making another.

-- Registry of active sub-adapter instances, keyed by file extension.
-- Populated lazily on first use (unconfigured defaults) or eagerly by __call.
local registry = {}

-- Sub-adapter factories, keyed by file extension.
local factories = {
  py = require("neotest-bazel-modular.python"),
}

-- Return the sub-adapter for a given file path, constructing a default
-- instance if the registry has not been explicitly configured yet.
local function sub(file_path)
  local ext = vim.fn.fnamemodify(file_path, ":e")
  if not registry[ext] and factories[ext] then
    registry[ext] = factories[ext]({})
  end
  return registry[ext]
end

-- Directories excluded from neotest's file scan.  Entries ending with "*"
-- are prefix-matched; all others are matched exactly against the dir name.
-- Replaced wholesale by opts.ignore_dirs when __call is invoked.
local DEFAULT_IGNORE_DIRS = { ".git", "node_modules", "vendor", "bazel-*" }
local ignore_dirs = DEFAULT_IGNORE_DIRS

local function dir_is_ignored(name)
  for _, entry in ipairs(ignore_dirs) do
    if entry:sub(-1) == "*" then
      if vim.startswith(name, entry:sub(1, -2)) then
        return true
      end
    elseif name == entry then
      return true
    end
  end
  return false
end

local Adapter = { name = "neotest-bazel-modular" }

-- Walk upward from the file to find the Bazel workspace root.
-- Replaced by opts.root when __call is invoked with a custom function.
local default_root = lib.files.match_root_pattern("MODULE.bazel", "WORKSPACE.bazel", "WORKSPACE")
Adapter.root = default_root

function Adapter.filter_dir(name, rel_path, root)
  return not dir_is_ignored(name)
end

function Adapter.is_test_file(file_path)
  local s = sub(file_path)
  return s ~= nil and s.is_test_file(file_path)
end

function Adapter.discover_positions(path)
  local s = sub(path)
  if s then
    return s.discover_positions(path)
  end
end

function Adapter.build_spec(args)
  local position = args.tree:data()
  local s = sub(position.path)
  if not s then
    return nil
  end
  -- Pass the file's directory, not the file: neotest always calls root() with
  -- a directory (and the `root` option documents that contract), so a custom
  -- resolver must see the same thing here.
  local root = Adapter.root(vim.fn.fnamemodify(position.path, ":h"))
  if not root then
    return nil
  end
  return s.build_spec(args, root)
end

function Adapter.results(spec, result, tree)
  local s = sub(tree:data().path)
  if s then
    return s.results(spec, result, tree)
  end
  return {}
end

-- Configuration entrypoint.
--
-- opts fields:
--   root             (function)  function(dir: string): string|nil
--                                Custom workspace-root finder.  Receives the
--                                directory of the file being tested and must
--                                return an absolute path to the workspace root,
--                                or nil when no root is found.  Defaults to
--                                walking up looking for MODULE.bazel /
--                                WORKSPACE.bazel / WORKSPACE.
--   bazel_binary     (string)    bazel executable passed to every sub-adapter,
--                                default "bazel"
--   target_resolver  (string)    how the Bazel target is resolved for each file:
--                                "treesitter" (default) - parse the nearest
--                                  BUILD.bazel/BUILD with treesitter; no
--                                  subprocess, but glob() srcs are not matched
--                                "query" - run `bazel query attr(srcs,...)`
--                                  synchronously; handles glob(), requires daemon
--                                Can be overridden per-language in the language
--                                config table.
--   ignore_dirs      (string[])  directory names excluded from neotest's scan.
--                                Entries ending with "*" are prefix-matched;
--                                all others are exact-matched against the name.
--                                Replaces the defaults entirely when supplied.
--                                Default: { ".git", "node_modules", "vendor",
--                                           "bazel-*" }
--   testlogs_symlink (string)    name of the bazel-testlogs convenience symlink
--                                under the workspace root, where JUnit XML is
--                                read from.  Global only (not per-language).
--                                Default: "bazel-testlogs"
--   python           (table|function)
--                                table - config overrides forwarded to the
--                                  built-in Python factory (args, is_test_file, ...)
--                                function - alternate factory that replaces the
--                                  built-in one entirely; called with the merged
--                                  base config
--
-- Example:
--   require("neotest-bazel-modular")({
--     bazel_binary = "bazelisk",
--     target_resolver = "treesitter",
--     ignore_dirs = { ".git", "node_modules", "vendor", "bazel-*", "_build" },
--     python = {
--       args = { "--config=ci" },
--       is_test_file = function(path) return path:match("_spec%.py$") end,
--     },
--   })
setmetatable(Adapter, {
  __call = function(_, opts)
    opts = opts or {}
    Adapter.root = type(opts.root) == "function" and opts.root or default_root
    local bazel_binary = opts.bazel_binary or "bazel"
    local target_resolver = opts.target_resolver or "treesitter"
    local testlogs_symlink = opts.testlogs_symlink or "bazel-testlogs"
    ignore_dirs = opts.ignore_dirs or DEFAULT_IGNORE_DIRS

    -- (Re-)populate the registry with freshly configured instances.
    -- Per-language opts can be either a config table or an alternate factory
    -- function; in the latter case it replaces the built-in factory entirely.
    -- target_resolver is part of the base config so language configs can
    -- override it individually; testlogs_symlink is global, applied after the
    -- per-language merge so a sub-config cannot shadow it.
    local lang_opts = {
      py = opts.python,
    }

    for ext, factory in pairs(factories) do
      local lo = lang_opts[ext]
      if type(lo) == "function" then
        registry[ext] = lo({
          bazel_binary = bazel_binary,
          target_resolver = target_resolver,
          testlogs_symlink = testlogs_symlink,
        })
      else
        local cfg = vim.tbl_extend("force", {
          bazel_binary = bazel_binary,
          target_resolver = target_resolver,
        }, lo or {})
        cfg.testlogs_symlink = testlogs_symlink
        registry[ext] = factory(cfg)
      end
    end

    return Adapter
  end,
})

return Adapter
