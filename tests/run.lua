-- Minimal synchronous in-process test runner.
-- Avoids plenary's child-spawning harness, which deadlocks when child nvim
-- processes load neotest (a nio async library) without an active event loop.

local results = { pass = 0, fail = 0 }
local describe_stack = {}
local before_each_stack = {} -- one slot per describe level

_G.describe = function(name, fn)
  describe_stack[#describe_stack + 1] = name
  before_each_stack[#before_each_stack + 1] = false -- false keeps ipairs alive; nil would truncate #
  fn()
  describe_stack[#describe_stack] = nil
  before_each_stack[#before_each_stack] = nil
end

_G.before_each = function(fn)
  before_each_stack[#before_each_stack] = fn
end

_G.it = function(name, fn)
  for _, bfn in ipairs(before_each_stack) do
    if bfn then
      bfn()
    end
  end
  local label = table.concat(describe_stack, " › ") .. " › " .. name
  local ok, err = pcall(fn)
  if ok then
    results.pass = results.pass + 1
    io.write("  ✓  " .. label .. "\n")
  else
    results.fail = results.fail + 1
    io.write("  ✗  " .. label .. "\n     " .. tostring(err) .. "\n")
  end
end

-- pending() marks a test as intentionally skipped.
_G.pending = function(name)
  io.write("  -  (pending) " .. name .. "\n")
end

-- Wire up luassert globals (assert.is_true, assert.are.same, etc.)
local ok, luassert = pcall(require, "luassert")
if ok then
  _G.assert = luassert
end

-- ── Run all spec files ────────────────────────────────────────────────────────

local spec_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h")
local specs = vim.fn.glob(spec_dir .. "/*_spec.lua", false, true)
table.sort(specs)

for _, spec in ipairs(specs) do
  io.write("\n" .. spec .. "\n")
  local load_ok, load_err = pcall(dofile, spec)
  if not load_ok then
    results.fail = results.fail + 1
    io.write("  ✗  (load error) " .. tostring(load_err) .. "\n")
  end
end

-- ── Summary ───────────────────────────────────────────────────────────────────

io.write(string.format("\n%d passed, %d failed\n", results.pass, results.fail))

if results.fail > 0 then
  vim.cmd("cquit 1")
end
