-- Collect test results from Python unittest text output.
--
-- Parses "FAIL: method (module.ClassName)" and "ERROR: ..." lines from the
-- captured runner output.  All test positions found in the tree are reported
-- as "passed" by default; positions that appear in FAIL:/ERROR: lines are
-- updated to "failed".
--
-- This collector works WITHOUT JUnit XML and is intended for Bazel py_test
-- targets that run Python's built-in unittest runner without --junit-xml.
-- For pytest-based targets, prefer results.xml which captures richer state
-- (skipped, expected failures, parametrized sub-tests).
--
-- Configure explicitly:
--   require("neotest-bazel-modular")({
--     python = {
--       results_collector = require("neotest-bazel-modular.results.python_unittest").collect,
--     },
--   })

local function read_file(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local data = f:read("*a")
  f:close()
  return data
end

-- Map a unittest FAIL:/ERROR: description to a neotest position ID.
--   desc: "test_method (__main__.ClassName.test_method)"   -- Python 3.12+
--      or "test_method (__main__.ClassName)"               -- older Python
local function find_id(desc, by_class_method, by_method)
  local method = desc:match("^(%S+)")
  if not method then
    return nil
  end

  local qualified = desc:match("%(([^)]+)%)")
  if qualified then
    -- Class names start uppercase; module components are lowercase.
    local class = qualified:match("[A-Z]%w*")
    if class then
      local id = by_class_method[class .. "." .. method]
      if id then
        return id
      end
    end
  end

  -- Fall back to method-name lookup when it is unique within the file.
  local ids = by_method[method]
  if ids and #ids == 1 then
    return ids[1]
  end
  return nil
end

local M = {}

-- Returns table<string, {status}>, or nil when the tree has no test positions
-- (e.g. when called for a position type the tree walk produces nothing for).
function M.collect(spec, result, tree)
  local by_class_method = {}
  local by_method = {}
  local results = {}

  for _, node in tree:iter_nodes() do
    local data = node:data()
    if data.type == "test" then
      results[data.id] = { status = "passed" }
      by_method[data.name] = by_method[data.name] or {}
      table.insert(by_method[data.name], data.id)
      local parent = node:parent()
      if parent and parent:data().type == "namespace" then
        by_class_method[parent:data().name .. "." .. data.name] = data.id
      end
    end
  end

  if vim.tbl_isempty(results) then
    return nil
  end

  local log = (result.output and read_file(result.output)) or ""

  for desc in log:gmatch("FAIL:%s+(.-)%s*\n") do
    local id = find_id(desc, by_class_method, by_method)
    if id then
      results[id] = { status = "failed" }
    end
  end
  for desc in log:gmatch("ERROR:%s+(.-)%s*\n") do
    local id = find_id(desc, by_class_method, by_method)
    if id then
      results[id] = { status = "failed" }
    end
  end

  return results
end

return M
