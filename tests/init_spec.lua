local Adapter = require("neotest-bazel-modular")

-- ── filter_dir ────────────────────────────────────────────────────────────────

describe("Adapter.filter_dir", function()
  it("excludes bazel-bin", function()
    assert.is_false(Adapter.filter_dir("bazel-bin", "bazel-bin", "/ws"))
  end)

  it("excludes bazel-out", function()
    assert.is_false(Adapter.filter_dir("bazel-out", "bazel-out", "/ws"))
  end)

  it("excludes any directory starting with bazel-", function()
    assert.is_false(Adapter.filter_dir("bazel-testlogs", "bazel-testlogs", "/ws"))
    assert.is_false(Adapter.filter_dir("bazel-myrepo", "bazel-myrepo", "/ws"))
  end)

  it("excludes .git", function()
    assert.is_false(Adapter.filter_dir(".git", ".git", "/ws"))
  end)

  it("excludes node_modules", function()
    assert.is_false(Adapter.filter_dir("node_modules", "node_modules", "/ws"))
  end)

  it("excludes vendor", function()
    assert.is_false(Adapter.filter_dir("vendor", "vendor", "/ws"))
  end)

  it("allows normal source directories", function()
    assert.is_true(Adapter.filter_dir("src", "src", "/ws"))
    assert.is_true(Adapter.filter_dir("lib", "lib", "/ws"))
    assert.is_true(Adapter.filter_dir("tests", "tests", "/ws"))
    assert.is_true(Adapter.filter_dir("my_package", "my_package", "/ws"))
  end)
end)

-- ── is_test_file routing ──────────────────────────────────────────────────────

describe("Adapter.is_test_file", function()
  it("delegates .py files to the Python sub-adapter", function()
    assert.is_true(Adapter.is_test_file("/ws/pkg/test_foo.py"))
    assert.is_false(Adapter.is_test_file("/ws/pkg/plain.py"))
  end)

  it("returns false for unrecognised extensions", function()
    assert.is_false(Adapter.is_test_file("/ws/pkg/test_foo.rs"))
    assert.is_false(Adapter.is_test_file("/ws/pkg/test_foo.go"))
  end)
end)

-- ── configuration ─────────────────────────────────────────────────────────────

describe("Adapter configuration via __call", function()
  it("returns the Adapter itself for method chaining", function()
    local result = Adapter({})
    assert.are.equal(Adapter, result)
  end)

  it("accepts bazel_binary without error", function()
    assert.has_no_error(function()
      Adapter({ bazel_binary = "bazelisk" })
    end)
  end)

  it("accepts python config table without error", function()
    assert.has_no_error(function()
      Adapter({
        bazel_binary = "bazelisk",
        python = { args = { "--config=ci" } },
      })
    end)
  end)

  it("accepts python as an alternate factory function", function()
    local called_with
    local fake_factory = function(cfg)
      called_with = cfg
      return {
        is_test_file = function()
          return false
        end,
        discover_positions = function() end,
        build_spec = function() end,
        results = function()
          return {}
        end,
      }
    end

    Adapter({ bazel_binary = "mybazel", python = fake_factory })

    -- The factory should receive at least the top-level bazel_binary.
    assert.are.equal("mybazel", called_with.bazel_binary)
  end)

  it("routes is_test_file through an alternate python factory", function()
    local custom = function(_cfg)
      return {
        is_test_file = function(p)
          return p:match("_spec%.py$") ~= nil
        end,
        discover_positions = function() end,
        build_spec = function() end,
        results = function()
          return {}
        end,
      }
    end

    Adapter({ python = custom })

    assert.is_true(Adapter.is_test_file("/ws/foo_spec.py"))
    assert.is_false(Adapter.is_test_file("/ws/test_foo.py"))

    -- Restore default so other tests are not affected.
    Adapter({})
  end)
end)
