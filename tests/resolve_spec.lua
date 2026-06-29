-- Tests the tree-sitter target resolver: that resolve.treesitter walks up to
-- the nearest BUILD file, parses it with the starlark grammar, and returns the
-- "//pkg:name" label of the rule whose literal srcs contains the file.
--
-- Only the BUILD file needs to exist on disk; the source file is matched by
-- string, so these specs write BUILD files into a temp workspace and pass
-- synthetic source paths under it.

local resolve = require("neotest-bazel-modular.resolve")

-- Create a temp workspace root and return its path.
local function workspace()
  local root = vim.fn.tempname()
  vim.fn.mkdir(root, "p")
  return root
end

-- Write `content` to <root>/<rel>/BUILD.bazel (rel may be "" for the root pkg).
local function write_build(root, rel, content, name)
  name = name or "BUILD.bazel"
  local dir = rel == "" and root or (root .. "/" .. rel)
  vim.fn.mkdir(dir, "p")
  vim.fn.writefile(vim.split(content, "\n"), dir .. "/" .. name)
end

describe("resolve.treesitter", function()
  it("resolves a list-srcs rule in the root package", function()
    local root = workspace()
    write_build(
      root,
      "",
      [[
py_test(
    name = "list_target",
    srcs = ["test_list.py"],
)
]]
    )
    assert.are.equal("//:list_target", resolve.treesitter(root .. "/test_list.py", root))
  end)

  it("resolves a bare-string srcs rule", function()
    local root = workspace()
    write_build(
      root,
      "",
      [[
py_test(
    name = "string_target",
    srcs = "test_string.py",
)
]]
    )
    assert.are.equal("//:string_target", resolve.treesitter(root .. "/test_string.py", root))
  end)

  it("builds a labelled package path for a subdirectory BUILD file", function()
    local root = workspace()
    write_build(
      root,
      "tests/unit",
      [[
py_test(
    name = "math",
    srcs = ["test_math.py"],
)
]]
    )
    assert.are.equal("//tests/unit:math", resolve.treesitter(root .. "/tests/unit/test_math.py", root))
  end)

  it("picks the rule whose srcs actually contains the file", function()
    local root = workspace()
    write_build(
      root,
      "",
      [[
py_test(name = "other", srcs = ["test_other.py"])
py_test(name = "mine", srcs = ["a.py", "test_mine.py", "b.py"])
]]
    )
    assert.are.equal("//:mine", resolve.treesitter(root .. "/test_mine.py", root))
  end)

  it("prefers a _test rule over a filegroup listing the same file", function()
    local root = workspace()
    write_build(
      root,
      "",
      [[
filegroup(name = "test_srcs", srcs = ["test_foo.py"])
py_test(name = "foo", srcs = ["test_foo.py"])
]]
    )
    -- The filegroup appears first, but the _test rule is preferred.
    assert.are.equal("//:foo", resolve.treesitter(root .. "/test_foo.py", root))
  end)

  it("falls back to a non-test rule when it is the only match", function()
    local root = workspace()
    write_build(root, "", [[filegroup(name = "test_srcs", srcs = ["test_foo.py"])]])
    -- No _test rule lists the file, so the only match is returned as-is.
    assert.are.equal("//:test_srcs", resolve.treesitter(root .. "/test_foo.py", root))
  end)

  it("prefers BUILD.bazel over BUILD when both exist", function()
    local root = workspace()
    write_build(root, "", [[py_test(name = "from_plain", srcs = ["t.py"])]], "BUILD")
    write_build(root, "", [[py_test(name = "from_bazel", srcs = ["t.py"])]], "BUILD.bazel")
    assert.are.equal("//:from_bazel", resolve.treesitter(root .. "/t.py", root))
  end)

  it("returns nil when no rule lists the file", function()
    local root = workspace()
    write_build(root, "", [[py_test(name = "x", srcs = ["something_else.py"])]])
    assert.is_nil(resolve.treesitter(root .. "/test_missing.py", root))
  end)

  it("returns nil when there is no BUILD file at all", function()
    local root = workspace()
    assert.is_nil(resolve.treesitter(root .. "/test_orphan.py", root))
  end)

  it("does not match glob() (non-literal srcs)", function()
    local root = workspace()
    write_build(root, "", [[py_test(name = "globbed", srcs = glob(["*.py"]))]])
    assert.is_nil(resolve.treesitter(root .. "/test_globbed.py", root))
  end)
end)
