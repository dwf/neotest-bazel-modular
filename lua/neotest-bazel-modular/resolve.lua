-- Target resolution strategies.
--
-- Each exported function maps a test file path + workspace root to a Bazel
-- target label string (e.g. "//tests/unit:test_foo"), or returns nil when
-- resolution fails.  Language sub-adapters select a strategy via the
-- `target_resolver` config key ("treesitter" or "query").

local M = {}

-- treesitter helpers

local function strip_quotes(s)
  return s:match('^"(.*)"$') or s:match("^'(.*)'$") or s
end

-- Walk up from dir toward root (inclusive on both ends), checking each
-- directory for BUILD.bazel first (Bazel's stated preference when both
-- exist), then BUILD.  Returns (build_path, build_dir) or (nil, nil).
local function find_build_file(dir, root)
  local d = dir
  while true do
    local b = d .. "/BUILD.bazel"
    if vim.fn.filereadable(b) == 1 then
      return b, d
    end
    b = d .. "/BUILD"
    if vim.fn.filereadable(b) == 1 then
      return b, d
    end
    if d == root then
      break
    end
    local parent = vim.fn.fnamemodify(d, ":h")
    if parent == d then
      break
    end -- guard against reaching the filesystem root
    d = parent
  end
  return nil, nil
end

-- Parse build_path with the starlark treesitter grammar and return the `name`
-- of a rule whose `srcs` contains src_path (relative to the directory
-- containing the BUILD file), or nil.
--
-- Among matching rules, prefer one whose kind ends in "_test" (py_test,
-- cc_test, go_test, ...) so a file also listed in a filegroup or library does
-- not resolve to a non-test target.  Fall back to the first match of any kind,
-- since a custom test macro may not follow the _test naming convention.
local function target_name_from_build(build_path, src_path)
  local lines = vim.fn.readfile(build_path)
  if not lines or #lines == 0 then
    return nil
  end
  local content = table.concat(lines, "\n")

  local ok, parser = pcall(vim.treesitter.get_string_parser, content, "starlark")
  if not ok then
    return nil
  end
  local tree = parser:parse()[1]
  if not tree then
    return nil
  end
  local root_node = tree:root()

  local first_match
  for i = 0, root_node:named_child_count() - 1 do
    local stmt = root_node:named_child(i)
    -- Top-level BUILD statements are expression_statements wrapping a call.
    local call
    if stmt:type() == "expression_statement" then
      call = stmt:named_child(0)
    elseif stmt:type() == "call" then
      call = stmt
    end
    if call and call:type() == "call" then
      -- The starlark grammar puts the callee first, then the argument_list.
      -- get_node_text handles both `py_test` and `native.py_test`.
      local fn = call:named_child(0)
      local kind = fn and vim.treesitter.get_node_text(fn, content) or ""
      local args
      for ci = 0, call:named_child_count() - 1 do
        local c = call:named_child(ci)
        if c:type() == "argument_list" then
          args = c
          break
        end
      end
      if args then
        local rule_name, in_srcs = nil, false
        for j = 0, args:named_child_count() - 1 do
          local kwarg = args:named_child(j)
          if kwarg:type() == "keyword_argument" then
            -- named_child(0) = identifier key, named_child(1) = value
            -- (named_child skips the anonymous "=" token)
            local k = kwarg:named_child(0)
            local v = kwarg:named_child(1)
            if k and v then
              local key = vim.treesitter.get_node_text(k, content)
              if key == "name" then
                rule_name = strip_quotes(vim.treesitter.get_node_text(v, content))
              elseif key == "srcs" and v:type() == "list" then
                for m = 0, v:named_child_count() - 1 do
                  local elem = v:named_child(m)
                  if strip_quotes(vim.treesitter.get_node_text(elem, content)) == src_path then
                    in_srcs = true
                    break
                  end
                end
              elseif key == "srcs" and v:type() == "string" then
                -- Bazel also allows a bare string srcs (srcs = "test_foo.py").
                if strip_quotes(vim.treesitter.get_node_text(v, content)) == src_path then
                  in_srcs = true
                end
              end
            end
          end
        end
        if rule_name and in_srcs then
          first_match = first_match or rule_name
          if kind:match("_test$") then
            return rule_name
          end
        end
      end
    end
  end
  return first_match
end

-- public resolvers

-- Resolve by parsing the nearest BUILD.bazel/BUILD file with treesitter.
-- Pure file I/O - no subprocess, no Bazel daemon required.
--
-- Returns the `name` of the first rule call whose literal srcs (a list or a
-- bare string) contains the file, and assumes that name is the runnable target
-- label.  That holds for plain rules and for macros that create a primary
-- target named exactly `name`, but NOT for macros that derive target names
-- from `name` (e.g. name .. "_test") -- those need target_resolver = "query".
--
-- Among matching rules it prefers one whose kind ends in "_test", so a file
-- also listed in a filegroup or library does not resolve to a non-test target.
-- This is a heuristic, not the query resolver's exact tests(//...) scoping: a
-- test rule whose kind does not end in "_test" is only chosen as a fallback,
-- and if the sole match is a non-test rule its label is still returned.
--
-- Does not handle glob() or non-literal srcs expressions; returns nil for
-- those (the caller should fall back or report no target found).
function M.treesitter(path, root)
  local file_dir = vim.fn.fnamemodify(path, ":h")
  local build_path, build_dir = find_build_file(file_dir, root)
  if not build_path then
    return nil
  end
  -- src_path is relative to build_dir so it matches the srcs entries as
  -- written (e.g. "test_foo.py" when BUILD is in the same dir, or
  -- "subdir/test_foo.py" when BUILD is in a parent directory).
  local src_path = path:sub(#build_dir + 2)
  local rule_name = target_name_from_build(build_path, src_path)
  if not rule_name then
    return nil
  end
  local pkg = build_dir:sub(#root + 2) -- "" for the root package
  return "//" .. pkg .. ":" .. rule_name
end

-- Resolve by running `bazel query attr(srcs,...)` synchronously.
-- Handles glob() and any other Bazel expression in srcs, but requires a
-- running Bazel daemon.  When multiple targets match, returns the first one.
--
-- The query is scoped to tests(//...) rather than //... so it only ever
-- returns runnable test targets -- otherwise a file also listed in a
-- filegroup or library could resolve to a non-test target that `bazel test`
-- rejects.  tests() also expands test_suite targets to their constituent tests.
function M.query(path, root, bazel)
  local rel_path = path:sub(#root + 2)
  local pkg = vim.fn.fnamemodify(rel_path, ":h")
  local base_name = vim.fn.fnamemodify(rel_path, ":t")
  if pkg == "." then
    pkg = ""
  end
  -- Escape dots so they are literal in Bazel's Java-regex attr() matcher.
  local file_label = "//" .. pkg .. ":" .. base_name:gsub("%.", "\\.")
  local out = vim.fn.system(
    string.format(
      "cd %s && %s query \"attr(srcs, '%s', tests(//...))\" 2>/dev/null | head -1",
      vim.fn.shellescape(root),
      bazel,
      file_label
    )
  )
  return out:match("([^\n]+)")
end

return M
