-- lib.treesitter.parse_positions is a nio async function; calling it from
-- plenary's synchronous test context deadlocks.  Instead, drive vim.treesitter
-- directly with the same query string the adapter uses.  This tests the only
-- thing that matters here: that the query captures exactly the right nodes.

local python_factory = require("neotest-bazel-modular.python")
local python = python_factory({})
local QUERY = python_factory._QUERY

local fixtures = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h") .. "/fixtures/python"

-- Run the adapter's treesitter query against a file and return two sorted
-- lists: namespace (class) names and test function/method names.
local function query_file(rel_path)
  local path = fixtures .. "/" .. rel_path
  local lines = vim.fn.readfile(path)
  assert(#lines > 0, "fixture file not found or empty: " .. path)
  local content = table.concat(lines, "\n")

  local parser = vim.treesitter.get_string_parser(content, "python")
  local root = parser:parse()[1]:root()
  local q = vim.treesitter.query.parse("python", QUERY)

  local namespaces, tests = {}, {}
  for id, node in q:iter_captures(root, content) do
    local cap = q.captures[id]
    local text = vim.treesitter.get_node_text(node, content)
    if cap == "namespace.name" then
      namespaces[#namespaces + 1] = text
    elseif cap == "test.name" then
      tests[#tests + 1] = text
    end
  end
  table.sort(namespaces)
  table.sort(tests)
  return namespaces, tests
end

-- ── is_test_file ──────────────────────────────────────────────────────────────

describe("python.is_test_file", function()
  it("accepts test_*.py", function()
    assert.is_true(python.is_test_file("/project/test_foo.py"))
  end)

  it("accepts *_test.py", function()
    assert.is_true(python.is_test_file("/project/foo_test.py"))
  end)

  it("rejects files without test prefix or suffix", function()
    assert.is_false(python.is_test_file("/project/plain.py"))
    assert.is_false(python.is_test_file("/project/helpers.py"))
  end)

  it("rejects test_ prefix on non-.py files", function()
    assert.is_false(python.is_test_file("/project/test_foo.js"))
    assert.is_false(python.is_test_file("/project/test_foo.lua"))
  end)

  it("rejects helper_test — must start with test_ or end with _test", function()
    assert.is_false(python.is_test_file("/project/helper_tests.py"))
  end)
end)

-- ── treesitter query — top-level functions ────────────────────────────────────

describe("python query — top-level functions (test_simple.py)", function()
  local ns, tests

  before_each(function()
    ns, tests = query_file("test_simple.py")
  end)

  it("finds test_ functions", function()
    assert.is_true(vim.tbl_contains(tests, "test_passes"))
    assert.is_true(vim.tbl_contains(tests, "test_another"))
  end)

  it("excludes functions not starting with test_", function()
    assert.is_false(vim.tbl_contains(tests, "not_a_test"))
    assert.is_false(vim.tbl_contains(tests, "helper_test"))
  end)

  it("produces no namespace nodes", function()
    assert.are.same({}, ns)
  end)
end)

-- ── treesitter query — TestCase classes ───────────────────────────────────────

describe("python query — TestCase classes (test_unittest.py)", function()
  local ns, tests

  before_each(function()
    ns, tests = query_file("test_unittest.py")
  end)

  it("discovers TestCase subclasses as namespaces", function()
    assert.is_true(vim.tbl_contains(ns, "TestWithBareBase"))
    assert.is_true(vim.tbl_contains(ns, "TestWithQualifiedBase"))
  end)

  it("treats all classes (including plain) as namespaces", function()
    assert.is_true(vim.tbl_contains(ns, "PlainClass"))
  end)

  it("discovers test_ methods inside TestCase subclasses", function()
    assert.is_true(vim.tbl_contains(tests, "test_method_a"))
    assert.is_true(vim.tbl_contains(tests, "test_method_b"))
    assert.is_true(vim.tbl_contains(tests, "test_qualified"))
  end)

  it("excludes non-test_ methods (setUp, etc.)", function()
    assert.is_false(vim.tbl_contains(tests, "setUp"))
  end)

  it("discovers test_ methods inside plain classes too (pytest style)", function()
    assert.is_true(vim.tbl_contains(tests, "test_ignored"))
    assert.is_true(vim.tbl_contains(tests, "test_also_ignored"))
  end)
end)

-- ── treesitter query — mixed file ─────────────────────────────────────────────

describe("python query — mixed file (test_mixed.py)", function()
  local ns, tests

  before_each(function()
    ns, tests = query_file("test_mixed.py")
  end)

  it("finds the top-level test function", function()
    assert.is_true(vim.tbl_contains(tests, "test_top_level"))
  end)

  it("finds the test method inside the TestCase class", function()
    assert.is_true(vim.tbl_contains(tests, "test_in_class"))
  end)

  it("finds the method inside the plain class (pytest style)", function()
    assert.is_true(vim.tbl_contains(tests, "test_not_included"))
  end)

  it("does NOT find non-test_ functions", function()
    assert.is_false(vim.tbl_contains(tests, "not_a_test"))
    assert.is_false(vim.tbl_contains(tests, "setUp"))
  end)
end)
