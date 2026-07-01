local junit = require("neotest-bazel-modular.results.junit")

-- Index the position tree neotest hands us so JUnit testcases can be matched
-- to the canonical position IDs assigned at discovery time.  This avoids
-- reconstructing those IDs from the XML, which would hardcode neotest's "::"
-- ID format and the "last classname component is the class" heuristic.
--   by_class_method: "ClassName.test_method" -> position id
--   by_method:       "test_method" -> { position id, ... }
local function index_positions(tree)
  local by_class_method = {}
  local by_method = {}
  for _, node in tree:iter_nodes() do
    local data = node:data()
    if data.type == "test" then
      by_method[data.name] = by_method[data.name] or {}
      table.insert(by_method[data.name], data.id)
      local parent = node:parent()
      if parent and parent:data().type == "namespace" then
        by_class_method[parent:data().name .. "." .. data.name] = data.id
      end
    end
  end
  return by_class_method, by_method
end

-- Map a JUnit <testcase classname=… name=…> to a neotest position ID.
local function find_id(classname, name, by_class_method, by_method)
  -- JUnit classname is dotted (e.g. "pkg.module.ClassName"); the class is its
  -- last component.
  local class = classname and classname:match("([^.]+)$")
  if class then
    local id = by_class_method[class .. "." .. name]
    if id then
      return id
    end
  end
  -- Fall back to the method name when it is unique across the tree (covers
  -- top-level functions, which have no namespace parent).
  local ids = by_method[name]
  if ids and #ids == 1 then
    return ids[1]
  end
  return nil
end

local M = {}

-- Collect test results from JUnit XML files under bazel-testlogs.
--
-- The Bazel target is read from spec.context.target (resolved at build_spec
-- time).  This locates the testlogs directory for that target and recurses into
-- it collecting every test.xml (handles sharded Bazel targets, via junit).
--
-- Each <testcase> is matched back to a position in `tree` (see
-- index_positions / find_id) so results carry neotest's own position IDs.
--
-- Returns table<position_id, {status}>, or nil when no target is set or no
-- test.xml files exist under the testlogs directory.
function M.collect(spec, result, tree)
  local by_class_method, by_method = index_positions(tree)
  local results = {}

  local processed = junit.for_each_testcase(spec, function(tc)
    local attr = tc._attr
    if attr and attr.name then
      local id = find_id(attr.classname, attr.name, by_class_method, by_method)
      if id then
        results[id] = {
          status = (tc.failure or tc.error) and "failed" or tc.skipped and "skipped" or "passed",
        }
      end
    end
  end)

  if not processed then
    return nil
  end
  return not vim.tbl_isempty(results) and results or nil
end

return M
