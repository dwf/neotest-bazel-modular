-- Tests the JUnit XML results collector's mapping logic: that each <testcase>
-- in the XML is matched back to the canonical neotest position ID assigned at
-- discovery time (via the position tree), with the right status.

local lib = require("neotest.lib")
local xml = require("neotest-bazel-modular.results.xml")

local PATH = "/proj/mypkg/test_foo.py"

-- Build a realistic position tree: a TestMath namespace with three methods,
-- plus one top-level test function.  parse_tree assigns the same "::"-joined
-- IDs neotest uses in production, which is exactly what we want to match.
local function build_tree()
  local positions = {
    { type = "file", path = PATH, name = "test_foo.py", range = { 0, 0, 100, 0 } },
    { type = "namespace", path = PATH, name = "TestMath", range = { 0, 0, 20, 0 } },
    { type = "test", path = PATH, name = "test_add", range = { 1, 0, 2, 0 } },
    { type = "test", path = PATH, name = "test_sub", range = { 3, 0, 4, 0 } },
    { type = "test", path = PATH, name = "test_skip", range = { 5, 0, 6, 0 } },
    { type = "test", path = PATH, name = "test_top", range = { 21, 0, 22, 0 } },
  }
  return lib.positions.parse_tree(positions, {})
end

-- Map test name -> canonical id, read straight from the tree (so the test
-- never hardcodes neotest's ID format).
local function ids_by_name(tree)
  local ids = {}
  for _, node in tree:iter_nodes() do
    local d = node:data()
    if d.type == "test" then
      ids[d.name] = d.id
    end
  end
  return ids
end

local JUNIT = [[<?xml version="1.0" encoding="UTF-8"?>
<testsuites>
  <testsuite name="mytest" tests="4" failures="1" errors="0" skipped="1">
    <testcase name="test_add" classname="mypkg.test_foo.TestMath"></testcase>
    <testcase name="test_sub" classname="mypkg.test_foo.TestMath">
      <failure message="boom">AssertionError: 1 != 2</failure>
    </testcase>
    <testcase name="test_skip" classname="mypkg.test_foo.TestMath">
      <skipped message="nope"></skipped>
    </testcase>
    <testcase name="test_top" classname="mypkg.test_foo"></testcase>
  </testsuite>
</testsuites>
]]

-- Write `content` to <root>/bazel-testlogs/<pkg>/<name>/test.xml and return a
-- spec whose context points the collector at it.
local function spec_with_xml(content)
  local root = vim.fn.tempname()
  local dir = root .. "/bazel-testlogs/mypkg/mytest"
  vim.fn.mkdir(dir, "p")
  vim.fn.writefile(vim.split(content, "\n"), dir .. "/test.xml")
  return {
    context = {
      target = "//mypkg:mytest",
      root = root,
      testlogs_symlink = "bazel-testlogs",
    },
  }
end

describe("results.xml collect — mapping", function()
  local results, ids

  before_each(function()
    local tree = build_tree()
    ids = ids_by_name(tree)
    results = xml.collect(spec_with_xml(JUNIT), {}, tree)
  end)

  it("maps a passing class method to its namespaced position id", function()
    assert.are.same({ status = "passed" }, results[ids["test_add"]])
  end)

  it("maps a <failure> testcase to failed", function()
    assert.are.same({ status = "failed" }, results[ids["test_sub"]])
  end)

  it("maps a <skipped> testcase to skipped", function()
    assert.are.same({ status = "skipped" }, results[ids["test_skip"]])
  end)

  it("matches a top-level function via the unique method-name fallback", function()
    -- classname "mypkg.test_foo" has no matching ClassName, so find_id falls
    -- back to the unique method name.
    assert.are.same({ status = "passed" }, results[ids["test_top"]])
  end)

  it("keys results by the tree's canonical ids only", function()
    local expected = {
      [ids["test_add"]] = true,
      [ids["test_sub"]] = true,
      [ids["test_skip"]] = true,
      [ids["test_top"]] = true,
    }
    for id in pairs(results) do
      assert.is_true(expected[id] == true, "unexpected result id: " .. id)
    end
  end)
end)

describe("results.xml collect — guards", function()
  it("returns nil when no target is set", function()
    local tree = build_tree()
    assert.is_nil(xml.collect({ context = {} }, {}, tree))
  end)

  it("returns nil when no test.xml exists under the testlogs dir", function()
    local tree = build_tree()
    local spec = {
      context = {
        target = "//mypkg:mytest",
        root = vim.fn.tempname(), -- nothing written here
        testlogs_symlink = "bazel-testlogs",
      },
    }
    assert.is_nil(xml.collect(spec, {}, tree))
  end)

  it("handles a root-package target (//:foo) without a doubled slash", function()
    -- tpkg is "" here; the testlogs path must be <root>/bazel-testlogs/foo,
    -- not <root>/bazel-testlogs//foo.
    local root = vim.fn.tempname()
    local dir = root .. "/bazel-testlogs/foo"
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile(vim.split(JUNIT, "\n"), dir .. "/test.xml")
    local tree = build_tree()
    local ids = ids_by_name(tree)
    local results = xml.collect({
      context = { target = "//:foo", root = root, testlogs_symlink = "bazel-testlogs" },
    }, {}, tree)
    assert.are.same({ status = "passed" }, results[ids["test_add"]])
    assert.are.same({ status = "failed" }, results[ids["test_sub"]])
  end)
end)
