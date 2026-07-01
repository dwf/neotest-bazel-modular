-- Collect results from a JUnit XML report produced by absl.testing.
--
-- absl.testing expands a single decorated test method into MANY <testcase>
-- entries -- one per parameterization (and failing subtests appear too):
--
--   @parameterized.parameters(...)        -> test_foo0, test_foo1, ...   (index)
--   @parameterized.named_parameters(...)  -> test_foo_<name>             (named)
--   self.subTest(...) that fails          -> "test_foo0 (x=1)" etc.
--
-- The neotest position tree, however, only has the DECORATED method
-- (test_foo), because tree-sitter discovery can't see runtime parameterization.
-- So each <testcase> is mapped back to the source method whose name it starts
-- with, and all cases/subtests of a method are aggregated into that one
-- position: any failing case fails the parent (subtests included).
--
-- Matching a testcase name to its source method:
--   * an exact match wins (a plain, non-parameterized test);
--   * otherwise the LONGEST source-method name that is a prefix of the testcase
--     name is the parent (base method + index / _name / subtest suffix).
-- Longest-prefix is a heuristic and is genuinely ambiguous when one method's
-- name is a parameterized expansion of another's in the same class (e.g. a real
-- `test_foo1` vs. `test_foo`'s case 1).  Preferring exact matches, and the
-- longest prefix otherwise, is the best that can be done from names alone;
-- order in the report is not reliable enough to disambiguate the rest.
--
-- Configure explicitly:
--   require("neotest-bazel-modular")({
--     python = {
--       results_collector = require("neotest-bazel-modular.results.xml_python_absl").collect,
--     },
--   })

local junit = require("neotest-bazel-modular.results.junit")

local CLASSLESS = "\0"

-- Group test positions by class name (namespace), preserving discovery order.
--   by_class: class_name -> { { name = , id = }, ... }
local function index_by_class(tree)
  local by_class = {}
  for _, node in tree:iter_nodes() do
    local d = node:data()
    if d.type == "test" then
      local parent = node:parent()
      local class = (parent and parent:data().type == "namespace") and parent:data().name or CLASSLESS
      by_class[class] = by_class[class] or {}
      table.insert(by_class[class], { name = d.name, id = d.id })
    end
  end
  return by_class
end

-- Find the source method id for an absl testcase name among `candidates`
-- (the positions of one class): exact match, else longest prefix.
local function find_source_id(candidates, name)
  if not candidates then
    return nil
  end
  for _, c in ipairs(candidates) do
    if c.name == name then
      return c.id
    end
  end
  local best_id, best_len = nil, -1
  for _, c in ipairs(candidates) do
    local m = c.name
    if #m > best_len and #name > #m and name:sub(1, #m) == m then
      best_id, best_len = c.id, #m
    end
  end
  return best_id
end

-- A failing case fails the parent; a pass beats a skip; all-skipped stays
-- skipped.
local RANK = { failed = 3, passed = 2, skipped = 1 }

local M = {}

-- Returns table<position_id, {status}>, or nil when no target is set or no
-- test.xml exists under the testlogs directory.
function M.collect(spec, result, tree)
  local by_class = index_by_class(tree)

  -- Flattened list for the fallback when a testcase's class isn't in the tree.
  local all = {}
  for _, list in pairs(by_class) do
    for _, c in ipairs(list) do
      all[#all + 1] = c
    end
  end

  -- All positions share the file being tested; use it to resolve traceback
  -- line numbers.
  local file_path = tree:data() and tree:data().path

  -- id -> { rank, status, errors }.  A parent's status is the max-rank of its
  -- cases (failure dominates); one errors entry is accumulated per failing case
  -- / subtest so the user sees which parameterizations failed.
  local acc = {}
  local processed = junit.for_each_testcase(spec, function(tc)
    local attr = tc._attr
    if not (attr and attr.name) then
      return
    end
    local class = attr.classname and attr.classname:match("([^.]+)$")
    local candidates = (class and by_class[class]) or by_class[CLASSLESS] or all
    local id = find_source_id(candidates, attr.name)
    if not id then
      return
    end

    local status = (tc.failure or tc.error) and "failed" or tc.skipped and "skipped" or "passed"
    local e = acc[id]
    if not e then
      e = { rank = 0, status = "skipped", errors = {} }
      acc[id] = e
    end
    if RANK[status] > e.rank then
      e.rank, e.status = RANK[status], status
    end
    if status == "failed" then
      local msg = junit.failure_message(tc)
      if msg then
        e.errors[#e.errors + 1] = {
          message = attr.name .. ": " .. msg,
          line = junit.failure_line(tc, file_path),
        }
      end
    end
  end)

  if not processed or next(acc) == nil then
    return nil
  end

  local results = {}
  for id, e in pairs(acc) do
    results[id] = { status = e.status, errors = (#e.errors > 0) and e.errors or nil }
  end
  return results
end

return M
