-- Collect test results from Python unittest text output.
--
-- unittest's default output does not name which tests passed (it prints one
-- char each), only which failed/errored (in the FAIL:/ERROR: summary blocks),
-- so the bazel exit code is used as the authoritative pass/fail signal for the
-- target as a whole:
--   * exit 0  -> the target passed; every position is reported passed.
--   * exit !0 -> read the output.  If unittest reached its "Ran N tests"
--                footer, the suite ran: the named FAIL:/ERROR: tests are
--                failed and the rest passed.  If the footer is absent the
--                suite crashed before running any test (e.g. an import error);
--                we cannot attribute that to a position, so return nil and let
--                the adapter fail the running position rather than report a
--                spurious all-green.
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
    -- The class is positional, not case-based: split the dotted qualified
    -- name and take the component before the method (3.12+ "module.Class.method")
    -- or the last component (older "module.Class").  Relying on capitalisation
    -- would mis-pick an uppercase-named module/package component.
    local parts = vim.split(qualified, ".", { plain = true })
    local class
    if parts[#parts] == method and #parts >= 2 then
      class = parts[#parts - 1]
    else
      class = parts[#parts]
    end
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
-- or the suite crashed before running (see the module comment).
function M.collect(spec, result, tree)
  local by_class_method = {}
  local by_method = {}
  local test_ids = {}

  for _, node in tree:iter_nodes() do
    local data = node:data()
    if data.type == "test" then
      test_ids[#test_ids + 1] = data.id
      by_method[data.name] = by_method[data.name] or {}
      table.insert(by_method[data.name], data.id)
      local parent = node:parent()
      if parent and parent:data().type == "namespace" then
        by_class_method[parent:data().name .. "." .. data.name] = data.id
      end
    end
  end

  if #test_ids == 0 then
    return nil
  end

  local results = {}
  local function seed_passed()
    for _, id in ipairs(test_ids) do
      results[id] = { status = "passed" }
    end
  end

  -- Exit 0 means the whole target passed; no output to parse.
  if result.code == 0 then
    seed_passed()
    return results
  end

  -- The target failed.  Only a completed run lets us treat "not named as a
  -- failure" as passed; a crash before the footer can't be attributed.
  local log = (result.output and read_file(result.output)) or ""
  if not log:match("Ran %d+ test") then
    return nil
  end

  seed_passed()
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
