-- Tests the absl.testing results collector: mapping parameterized/subtest
-- <testcase> entries back to their decorated source method, aggregating status
-- (any failure fails the parent), disambiguating prefix collisions, and
-- aggregating across shards.

local lib = require("neotest.lib")
local absl = require("neotest-bazel-modular.results.xml_python_absl")

local PATH = "/proj/mypkg/test_math.py"

-- Class TestMath with several decorated methods (each is ONE source position,
-- as tree-sitter sees it).  test_pre / test_prefix exercise prefix collision.
local function build_tree()
  local positions = {
    { type = "file", path = PATH, name = "test_math.py", range = { 0, 0, 200, 0 } },
    { type = "namespace", path = PATH, name = "TestMath", range = { 0, 0, 199, 0 } },
    { type = "test", path = PATH, name = "test_add", range = { 1, 0, 2, 0 } },
    { type = "test", path = PATH, name = "test_sub", range = { 3, 0, 4, 0 } },
    { type = "test", path = PATH, name = "test_div", range = { 5, 0, 6, 0 } },
    { type = "test", path = PATH, name = "test_pre", range = { 7, 0, 8, 0 } },
    { type = "test", path = PATH, name = "test_prefix", range = { 9, 0, 10, 0 } },
    { type = "test", path = PATH, name = "test_skipall", range = { 11, 0, 12, 0 } },
    { type = "test", path = PATH, name = "test_withsub", range = { 13, 0, 14, 0 } },
  }
  return lib.positions.parse_tree(positions, {})
end

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

-- Build an absl-style <testcase> for class TestMath.
--   kind: "pass" | "fail" | "skip"
local function tc(name, kind)
  local body = ""
  if kind == "fail" then
    body = '<failure message="boom">AssertionError</failure>'
  elseif kind == "skip" then
    body = '<skipped message="nope"></skipped>'
  end
  return ('    <testcase classname="__main__.TestMath" name="%s">%s</testcase>'):format(name, body)
end

local function suite(cases)
  return table.concat({
    '<?xml version="1.0" encoding="UTF-8"?>',
    "<testsuites>",
    '  <testsuite name="TestMath">',
    table.concat(cases, "\n"),
    "  </testsuite>",
    "</testsuites>",
    "",
  }, "\n")
end

-- Write two shards under <root>/bazel-testlogs/mypkg/mytest/shard_N_of_2/ and
-- return a spec pointing the collector at the target.
local function spec_with_shards(shard1, shard2)
  local root = vim.fn.tempname()
  local d1 = root .. "/bazel-testlogs/mypkg/mytest/shard_1_of_2"
  local d2 = root .. "/bazel-testlogs/mypkg/mytest/shard_2_of_2"
  vim.fn.mkdir(d1, "p")
  vim.fn.mkdir(d2, "p")
  vim.fn.writefile(vim.split(shard1, "\n"), d1 .. "/test.xml")
  vim.fn.writefile(vim.split(shard2, "\n"), d2 .. "/test.xml")
  return {
    context = { target = "//mypkg:mytest", root = root, testlogs_symlink = "bazel-testlogs" },
  }
end

describe("results.xml_python_absl collect", function()
  local results, ids

  before_each(function()
    local tree = build_tree()
    ids = ids_by_name(tree)

    local shard1 = suite({
      tc("test_add0", "pass"), -- unnamed params, all pass
      tc("test_add1", "pass"),
      tc("test_sub_normal", "pass"), -- named params, one fails
      tc("test_sub_negative", "fail"),
      tc("test_pre0", "pass"), -- prefix collision: test_pre passes ...
      tc("test_prefix0", "fail"), -- ... test_prefix (longer) fails
      tc("test_skipall0", "skip"), -- all cases skipped
      tc("test_skipall1", "skip"),
      tc("test_withsub", "pass"), -- base passes ...
      tc("test_withsub (widget=1)", "fail"), -- ... but a subtest fails
      tc("test_div0", "pass"), -- test_div: one case per shard
    })
    local shard2 = suite({
      tc("test_div1", "fail"), -- cross-shard aggregation
    })

    results = absl.collect(spec_with_shards(shard1, shard2), {}, tree)
  end)

  it("passes a method when all its unnamed parameterizations pass", function()
    assert.are.same({ status = "passed" }, results[ids["test_add"]])
  end)

  it("fails a method when a named parameterization fails", function()
    assert.are.same({ status = "failed" }, results[ids["test_sub"]])
  end)

  it("fails a method when a subtest fails even though the base passed", function()
    assert.are.same({ status = "failed" }, results[ids["test_withsub"]])
  end)

  it("aggregates parameterizations across shards", function()
    -- test_div0 (shard 1) passed, test_div1 (shard 2) failed.
    assert.are.same({ status = "failed" }, results[ids["test_div"]])
  end)

  it("marks a method skipped when all its cases are skipped", function()
    assert.are.same({ status = "skipped" }, results[ids["test_skipall"]])
  end)

  it("disambiguates a prefix collision by longest prefix", function()
    -- test_prefix0 must map to test_prefix (longer), not test_pre.
    assert.are.same({ status = "passed" }, results[ids["test_pre"]])
    assert.are.same({ status = "failed" }, results[ids["test_prefix"]])
  end)
end)

describe("results.xml_python_absl collect — exact match precedence", function()
  it("maps an exact name to that method, not a shorter parameterized parent", function()
    -- Both test_foo (parameterized) and a real test_foo0 exist; the testcase
    -- named exactly test_foo0 belongs to the real method.
    local tree = lib.positions.parse_tree({
      { type = "file", path = PATH, name = "test_math.py", range = { 0, 0, 100, 0 } },
      { type = "namespace", path = PATH, name = "TestMath", range = { 0, 0, 99, 0 } },
      { type = "test", path = PATH, name = "test_foo", range = { 1, 0, 2, 0 } },
      { type = "test", path = PATH, name = "test_foo0", range = { 3, 0, 4, 0 } },
    }, {})
    local ids = ids_by_name(tree)
    local root = vim.fn.tempname()
    local dir = root .. "/bazel-testlogs/mypkg/mytest"
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile(vim.split(suite({ tc("test_foo0", "fail") }), "\n"), dir .. "/test.xml")
    local results = absl.collect({
      context = { target = "//mypkg:mytest", root = root, testlogs_symlink = "bazel-testlogs" },
    }, {}, tree)
    assert.are.same({ status = "failed" }, results[ids["test_foo0"]])
    assert.is_nil(results[ids["test_foo"]])
  end)
end)
