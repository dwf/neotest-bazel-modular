-- Tests runner.build_spec's shell command construction: the static
-- opts.args (from adapter config) and the per-run args.extra_args (from
-- e.g. `require("neotest").run.run({ extra_args = {...} })`) must both reach
-- the `bazel test` invocation, with extra_args appended last so it can
-- override the static config.

local runner = require("neotest-bazel-modular.runner")

local function workspace()
  local root = vim.fn.tempname()
  vim.fn.mkdir(root, "p")
  return root
end

local function write_build(root, content)
  vim.fn.writefile(vim.split(content, "\n"), root .. "/BUILD.bazel")
end

local function tree_for(path)
  return {
    data = function()
      return { path = path, id = path }
    end,
  }
end

describe("runner.build_spec", function()
  it("appends args.extra_args after the static opts.args", function()
    local root = workspace()
    write_build(root, [[py_test(name = "t", srcs = ["test_foo.py"])]])

    local spec = runner.build_spec(
      { tree = tree_for(root .. "/test_foo.py"), extra_args = { "--test_output=all" } },
      root,
      { bazel = "bazel", args = { "--config=ci" } }
    )

    assert.are.equal("sh", spec.command[1])
    assert.are.equal("-c", spec.command[2])
    assert.are.equal("bazel test '//:t' '--config=ci' '--test_output=all'", spec.command[3])
  end)

  it("omits extra_args when the run supplies none", function()
    local root = workspace()
    write_build(root, [[py_test(name = "t", srcs = ["test_foo.py"])]])

    local spec = runner.build_spec({ tree = tree_for(root .. "/test_foo.py") }, root, { bazel = "bazel" })

    assert.are.equal("bazel test '//:t' ", spec.command[3])
  end)
end)
