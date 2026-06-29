-- Tests the unittest text-output results collector, in particular that it uses
-- the bazel exit code as the authoritative signal and does not report a
-- spurious all-green when the suite crashes before running.

local lib = require("neotest.lib")
local unittest = require("neotest-bazel-modular.results.python_unittest")

local PATH = "/proj/mypkg/test_foo.py"

local function build_tree()
  local positions = {
    { type = "file", path = PATH, name = "test_foo.py", range = { 0, 0, 100, 0 } },
    { type = "namespace", path = PATH, name = "TestMath", range = { 0, 0, 20, 0 } },
    { type = "test", path = PATH, name = "test_add", range = { 1, 0, 2, 0 } },
    { type = "test", path = PATH, name = "test_sub", range = { 3, 0, 4, 0 } },
    { type = "test", path = PATH, name = "test_mul", range = { 5, 0, 6, 0 } },
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

-- A tree with the SAME method name in two classes, so the unique-method-name
-- fallback cannot resolve it -- forcing find_id to extract the class correctly.
local function build_dup_tree()
  local positions = {
    { type = "file", path = PATH, name = "test_foo.py", range = { 0, 0, 100, 0 } },
    { type = "namespace", path = PATH, name = "TestMath", range = { 0, 0, 10, 0 } },
    { type = "test", path = PATH, name = "test_dup", range = { 1, 0, 2, 0 } },
    { type = "namespace", path = PATH, name = "TestPhys", range = { 11, 0, 20, 0 } },
    { type = "test", path = PATH, name = "test_dup", range = { 12, 0, 13, 0 } },
  }
  return lib.positions.parse_tree(positions, {})
end

-- Map "Class.method" -> id (needed when method names are not unique).
local function ids_by_class_method(tree)
  local ids = {}
  for _, node in tree:iter_nodes() do
    local d = node:data()
    if d.type == "test" then
      local parent = node:parent()
      if parent and parent:data().type == "namespace" then
        ids[parent:data().name .. "." .. d.name] = d.id
      end
    end
  end
  return ids
end

-- Build a fake neotest `result` with the given exit code and (optional) log
-- text written to result.output.
local function result_with(code, log)
  local output
  if log then
    output = vim.fn.tempname()
    vim.fn.writefile(vim.split(log, "\n"), output)
  end
  return { code = code, output = output }
end

describe("results.python_unittest collect", function()
  local tree, ids

  before_each(function()
    tree = build_tree()
    ids = ids_by_name(tree)
  end)

  it("reports every position passed when the target exits 0", function()
    -- No output at all (e.g. --test_output=errors on a passing run).
    local r = unittest.collect({}, result_with(0, nil), tree)
    assert.are.same({ status = "passed" }, r[ids["test_add"]])
    assert.are.same({ status = "passed" }, r[ids["test_sub"]])
    assert.are.same({ status = "passed" }, r[ids["test_mul"]])
  end)

  it("marks named failures failed and the rest passed on a completed run", function()
    local log = table.concat({
      "F..",
      "======================================================================",
      "FAIL: test_add (mypkg.test_foo.TestMath.test_add)",
      "----------------------------------------------------------------------",
      "Traceback (most recent call last):",
      "AssertionError: 1 != 2",
      "",
      "----------------------------------------------------------------------",
      "Ran 3 tests in 0.001s",
      "",
      "FAILED (failures=1)",
      "",
    }, "\n")
    local r = unittest.collect({}, result_with(3, log), tree)
    assert.are.same({ status = "failed" }, r[ids["test_add"]])
    assert.are.same({ status = "passed" }, r[ids["test_sub"]])
    assert.are.same({ status = "passed" }, r[ids["test_mul"]])
  end)

  it("treats ERROR: blocks as failed", function()
    local log = table.concat({
      "E..",
      "ERROR: test_sub (mypkg.test_foo.TestMath.test_sub)",
      "----------------------------------------------------------------------",
      "Ran 3 tests in 0.001s",
      "",
      "FAILED (errors=1)",
      "",
    }, "\n")
    local r = unittest.collect({}, result_with(3, log), tree)
    assert.are.same({ status = "failed" }, r[ids["test_sub"]])
    assert.are.same({ status = "passed" }, r[ids["test_add"]])
  end)

  it("returns nil when the suite crashed before running (no footer)", function()
    -- An import error: non-zero exit, traceback, no "Ran N tests" footer.
    local log = table.concat({
      "Traceback (most recent call last):",
      '  File "test_foo.py", line 3, in <module>',
      "    import nonexistent",
      "ModuleNotFoundError: No module named 'nonexistent'",
      "",
    }, "\n")
    assert.is_nil(unittest.collect({}, result_with(1, log), tree))
  end)

  it("returns nil when the tree has no test positions", function()
    local empty = lib.positions.parse_tree({
      { type = "file", path = PATH, name = "test_foo.py", range = { 0, 0, 1, 0 } },
    }, {})
    assert.is_nil(unittest.collect({}, result_with(0, nil), empty))
  end)

  -- The qualified name has an UPPERCASE package component (Acme), and the
  -- method name is duplicated across two classes, so the only way to attribute
  -- the failure correctly is to extract the class positionally.
  it("attributes the failure to the right class with an uppercase package (3.12+ form)", function()
    local dup = build_dup_tree()
    local ids = ids_by_class_method(dup)
    local log = table.concat({
      "F.",
      "FAIL: test_dup (Acme.mathlib.TestPhys.test_dup)",
      "----------------------------------------------------------------------",
      "Ran 2 tests in 0.001s",
      "",
      "FAILED (failures=1)",
      "",
    }, "\n")
    local r = unittest.collect({}, result_with(3, log), dup)
    assert.are.same({ status = "failed" }, r[ids["TestPhys.test_dup"]])
    assert.are.same({ status = "passed" }, r[ids["TestMath.test_dup"]])
  end)

  it("attributes the failure with the older module.Class form", function()
    local dup = build_dup_tree()
    local ids = ids_by_class_method(dup)
    local log = table.concat({
      "F.",
      "FAIL: test_dup (Acme.mathlib.TestPhys)",
      "----------------------------------------------------------------------",
      "Ran 2 tests in 0.001s",
      "",
      "FAILED (failures=1)",
      "",
    }, "\n")
    local r = unittest.collect({}, result_with(3, log), dup)
    assert.are.same({ status = "failed" }, r[ids["TestPhys.test_dup"]])
    assert.are.same({ status = "passed" }, r[ids["TestMath.test_dup"]])
  end)
end)
