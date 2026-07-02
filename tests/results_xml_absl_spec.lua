-- Tests the absl.testing results collector: mapping parameterized/subtest
-- <testcase> entries back to their decorated source method, aggregating status
-- (any failure fails the parent) and failure messages, disambiguating prefix
-- collisions, aggregating across shards, and parsing traceback line numbers.
--
-- The <testcase> names here are the real ones absl emits (verified against a
-- live absl run): unnamed params are "{method}{index} (repr)", named params are
-- "{method}_{casename}", and failing subtests are "{method} (kwargs)".

local lib = require("neotest.lib")
local absl = require("neotest-bazel-modular.results.xml_python_absl")

local PATH = "/proj/mypkg/test_math.py"

-- Class TestMath with several decorated methods (each is ONE source position,
-- as tree-sitter sees it).
--   test_pre / test_prefix      -- prefix collision between two unnamed-param methods
--   test_calc / test_calc_values -- a named-param method whose name is a prefix of
--                                   a subtest method (the real collision absl produces)
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
    { type = "test", path = PATH, name = "test_multi", range = { 15, 0, 16, 0 } },
    { type = "test", path = PATH, name = "test_calc", range = { 17, 0, 18, 0 } },
    { type = "test", path = PATH, name = "test_calc_values", range = { 19, 0, 20, 0 } },
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

-- Build an absl-style <testcase> for class TestMath.  `name` is a real absl
-- expansion name (see the ground truth in tests/parametrized of the playground):
--   unnamed:  "test_add0 (0, 0, 0)"      -- {method}{index} + " (repr)"
--   named:    "test_sub_normal"          -- {method}_{casename}
--   subtest:  "test_withsub (widget=1)"  -- {method} + " (kwargs)"
--   kind: "pass" | "fail" | "skip"; `body` is the <failure> element text.
local function tc(name, kind, body)
  local inner = ""
  if kind == "fail" then
    inner = ('<failure message="boom">%s</failure>'):format(body or "AssertionError")
  elseif kind == "skip" then
    inner = '<skipped message="nope"></skipped>'
  end
  return ('    <testcase classname="__main__.TestMath" name="%s">%s</testcase>'):format(name, inner)
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
      tc("test_add0 (0, 0, 0)", "pass"), -- unnamed params, all pass
      tc("test_add1 (2, 3, 5)", "pass"),
      tc("test_sub_normal", "pass"), -- named params, one fails
      tc("test_sub_negative", "fail"),
      tc("test_pre0 (1,)", "pass"), -- prefix collision: test_pre passes ...
      tc("test_prefix0 (1,)", "fail"), -- ... test_prefix (longer) fails
      tc("test_calc_zero", "pass"), -- named param of test_calc (passes) ...
      tc("test_calc_values (n=0)", "fail"), -- ... subtest of test_calc_values (fails)
      tc("test_skipall0 (1,)", "skip"), -- all cases skipped
      tc("test_skipall1 (2,)", "skip"),
      tc("test_withsub", "pass"), -- base passes ...
      tc("test_withsub (widget=1)", "fail"), -- ... but a subtest fails
      tc("test_div0 (1,)", "pass"), -- test_div: one case per shard
      tc("test_multi0 (1,)", "fail"), -- two failing cases -> two errors
      tc("test_multi1 (2,)", "fail"),
    })
    local shard2 = suite({
      tc("test_div1 (2,)", "fail"), -- cross-shard aggregation
    })

    results = absl.collect(spec_with_shards(shard1, shard2), {}, tree)
  end)

  it("passes a method when all its unnamed parameterizations pass", function()
    assert.are.same({ status = "passed" }, results[ids["test_add"]])
  end)

  it("fails a method when a named parameterization fails, surfacing the case", function()
    local r = results[ids["test_sub"]]
    assert.are.equal("failed", r.status)
    assert.are.same({ { message = "test_sub_negative: boom" } }, r.errors)
  end)

  it("fails a method when a subtest fails even though the base passed", function()
    local r = results[ids["test_withsub"]]
    assert.are.equal("failed", r.status)
    assert.are.same({ { message = "test_withsub (widget=1): boom" } }, r.errors)
  end)

  it("accumulates one error entry per failing case", function()
    local r = results[ids["test_multi"]]
    assert.are.equal("failed", r.status)
    assert.are.equal(2, #r.errors)
  end)

  it("aggregates parameterizations across shards", function()
    -- test_div0 (shard 1) passed, test_div1 (shard 2) failed.
    assert.are.equal("failed", results[ids["test_div"]].status)
  end)

  it("marks a method skipped when all its cases are skipped", function()
    assert.are.same({ status = "skipped" }, results[ids["test_skipall"]])
  end)

  it("disambiguates a prefix collision by longest prefix", function()
    -- test_prefix0 must map to test_prefix (longer), not test_pre.
    assert.are.same({ status = "passed" }, results[ids["test_pre"]])
    assert.are.equal("failed", results[ids["test_prefix"]].status)
  end)

  it("keeps a named-param method distinct from a subtest method it prefixes", function()
    -- test_calc (named -> test_calc_zero) vs test_calc_values (subtest ->
    -- "test_calc_values (n=0)").  The real collision absl produces.
    assert.are.same({ status = "passed" }, results[ids["test_calc"]])
    assert.are.equal("failed", results[ids["test_calc_values"]].status)
  end)
end)

describe("results.xml_python_absl collect — named_parameters source resolution", function()
  it("resolves a named expansion to its method, not a prefix sibling", function()
    -- The pathological case longest-prefix can't solve: test_foo's "nap" case
    -- expands to test_foo_nap, and a sibling test_foo_na has a name that is a
    -- prefix of it.  Parsing the decorator resolves test_foo_nap -> test_foo.
    local src = table.concat({
      "class TestMath(parameterized.TestCase):",
      '    @parameterized.named_parameters(("nap", 1))',
      "    def test_foo(self, x):",
      "        self.fail()",
      "",
      "    def test_foo_na(self):",
      "        pass",
      "",
    }, "\n")
    local path = vim.fn.tempname() .. ".py"
    vim.fn.writefile(vim.split(src, "\n"), path)

    local tree = lib.positions.parse_tree({
      { type = "file", path = path, name = "test_math.py", range = { 0, 0, 100, 0 } },
      { type = "namespace", path = path, name = "TestMath", range = { 0, 0, 99, 0 } },
      { type = "test", path = path, name = "test_foo", range = { 1, 0, 3, 0 } },
      { type = "test", path = path, name = "test_foo_na", range = { 5, 0, 6, 0 } },
    }, {})
    local ids = ids_by_name(tree)

    local root = vim.fn.tempname()
    local dir = root .. "/bazel-testlogs/mypkg/mytest"
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile(
      vim.split(suite({ tc("test_foo_nap", "fail"), tc("test_foo_na", "pass") }), "\n"),
      dir .. "/test.xml"
    )

    local results = absl.collect({
      context = { target = "//mypkg:mytest", root = root, testlogs_symlink = "bazel-testlogs" },
    }, {}, tree)

    -- The failure lands on test_foo (its case), not the passing sibling.
    assert.are.equal("failed", results[ids["test_foo"]].status)
    assert.are.same({ status = "passed" }, results[ids["test_foo_na"]])
  end)
end)

describe("results.xml_python_absl collect — raw absl entity encoding", function()
  it("decodes &#x20; in the testcase name before matching", function()
    -- Verbatim from a real absl JUnit report: absl encodes spaces as &#x20;.
    local tree = build_tree()
    local ids = ids_by_name(tree)
    local xml = table.concat({
      '<?xml version="1.0"?>',
      "<testsuites>",
      '  <testsuite name="TestMath">',
      '    <testcase classname="__main__.TestMath" name="test_add0&#x20;(2,&#x20;3,&#x20;5)">'
        .. '<failure message="boom">AssertionError</failure></testcase>',
      "  </testsuite>",
      "</testsuites>",
      "",
    }, "\n")
    local root = vim.fn.tempname()
    local dir = root .. "/bazel-testlogs/mypkg/mytest"
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile(vim.split(xml, "\n"), dir .. "/test.xml")

    local results = absl.collect({
      context = { target = "//mypkg:mytest", root = root, testlogs_symlink = "bazel-testlogs" },
    }, {}, tree)
    -- "test_add0 (2, 3, 5)" (decoded) maps to test_add.
    assert.are.equal("failed", results[ids["test_add"]].status)
    assert.are.same({ { message = "test_add0 (2, 3, 5): boom" } }, results[ids["test_add"]].errors)
  end)
end)

describe("results.xml_python_absl collect — traceback line numbers", function()
  it("parses the deepest test-file frame's line (0-indexed)", function()
    local tree = build_tree()
    local ids = ids_by_name(tree)
    local traceback = table.concat({
      "Traceback (most recent call last):",
      '  File "/some/runfiles/helpers.py", line 5, in wrapper',
      "    return fn()",
      '  File "/some/runfiles/mypkg/test_math.py", line 42, in test_add',
      "    self.assertEqual(1, 2)",
      "AssertionError: 1 != 2",
    }, "\n")
    local root = vim.fn.tempname()
    local dir = root .. "/bazel-testlogs/mypkg/mytest"
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile(vim.split(suite({ tc("test_add0 (1, 1)", "fail", traceback) }), "\n"), dir .. "/test.xml")

    local results = absl.collect({
      context = { target = "//mypkg:mytest", root = root, testlogs_symlink = "bazel-testlogs" },
    }, {}, tree)
    -- line 42 in test_math.py (the deepest frame in that file) -> 0-indexed 41.
    assert.are.equal(41, results[ids["test_add"]].errors[1].line)
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
    assert.are.equal("failed", results[ids["test_foo0"]].status)
    assert.is_nil(results[ids["test_foo"]])
  end)
end)
