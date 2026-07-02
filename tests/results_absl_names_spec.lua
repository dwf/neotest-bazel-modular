-- Tests the reconstruction of absl named_parameters expansion names from source.

local absl_names = require("neotest-bazel-modular.results.absl_names")

local function parse(src)
  local path = vim.fn.tempname() .. ".py"
  vim.fn.writefile(vim.split(src, "\n"), path)
  return absl_names.named_expansions(path)
end

describe("absl_names.named_expansions", function()
  it("extracts tuple-form case names (name first)", function()
    local m = parse([[
class T(parameterized.TestCase):
    @parameterized.named_parameters(
        ("normal", 1, 2),
        ("negative", -1, -2),
    )
    def test_add(self, a, b):
        pass
]])
    assert.are.equal("test_add", m.T["test_add_normal"])
    assert.are.equal("test_add", m.T["test_add_negative"])
  end)

  it("extracts dict-literal testcase_name (single and double quotes)", function()
    local m = parse([[
class T(parameterized.TestCase):
    @parameterized.named_parameters(
        {"testcase_name": "Double", "a": 1},
        {'testcase_name': 'Single', 'a': 2},
    )
    def test_x(self, a):
        pass
]])
    assert.are.equal("test_x", m.T["test_x_Double"])
    assert.are.equal("test_x", m.T["test_x_Single"])
  end)

  it("extracts dict() call testcase_name kwarg", function()
    local m = parse([[
class T(parameterized.TestCase):
    @parameterized.named_parameters(
        dict(testcase_name="Kw", a=1),
    )
    def test_y(self, a):
        pass
]])
    assert.are.equal("test_y", m.T["test_y_Kw"])
  end)

  it("handles the bare named_parameters import form", function()
    local m = parse([[
class T(parameterized.TestCase):
    @named_parameters(("solo", 1))
    def test_w(self, a):
        pass
]])
    assert.are.equal("test_w", m.T["test_w_solo"])
  end)

  it("scopes expansions per class", function()
    local m = parse([[
class A(parameterized.TestCase):
    @parameterized.named_parameters(("x", 1))
    def test_f(self, a):
        pass

class B(parameterized.TestCase):
    @parameterized.named_parameters(("y", 1))
    def test_f(self, a):
        pass
]])
    assert.are.equal("test_f", m.A["test_f_x"])
    assert.are.equal("test_f", m.B["test_f_y"])
    assert.is_nil(m.A["test_f_y"])
  end)

  it("does not touch @parameterized.parameters (unnamed)", function()
    local m = parse([[
class T(parameterized.TestCase):
    @parameterized.parameters(1, 2, 3)
    def test_u(self, x):
        pass
]])
    assert.is_nil((m.T or {})["test_u0"])
  end)

  it("ignores comprehension-generated cases (out of scope)", function()
    local m = parse([[
class T(parameterized.TestCase):
    @parameterized.named_parameters(
        *[("gen%d" % i, i) for i in range(3)]
    )
    def test_z(self, i):
        pass
]])
    assert.is_nil((m.T or {})["test_z_gen0"])
  end)

  it("returns an empty map for a missing file", function()
    assert.are.same({}, absl_names.named_expansions("/no/such/file.py"))
  end)
end)
