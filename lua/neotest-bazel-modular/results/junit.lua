-- Shared JUnit-XML plumbing for the results collectors: locating a Bazel
-- target's testlogs directory, walking it for every test.xml (sharding), and
-- iterating <testcase> elements.  The collectors themselves only implement how
-- a <testcase> maps to a neotest position.

local lib = require("neotest.lib")

local M = {}

function M.read_file(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local data = f:read("*a")
  f:close()
  return data
end

-- Recursively collect every test.xml under `dir` (handles sharded Bazel targets).
--
-- Recursion is gated on the scandir entry type being "directory", which does
-- not follow symlinks (a symlinked dir reports as "link" and would be skipped).
-- That is fine here: within a target's testlogs Bazel writes plain files and
-- shard subdirectories, never symlinks, so we never need to traverse one.
function M.find_xml_files(dir)
  local uv = vim.uv or vim.loop
  local files = {}
  local handle = uv.fs_scandir(dir)
  if not handle then
    return files
  end
  while true do
    local name, ftype = uv.fs_scandir_next(handle)
    if not name then
      break
    end
    local full_path = dir .. "/" .. name
    if ftype == "directory" then
      for _, f in ipairs(M.find_xml_files(full_path)) do
        files[#files + 1] = f
      end
    elseif name == "test.xml" then
      files[#files + 1] = full_path
    end
  end
  return files
end

-- Normalise xml2lua's single-element reduction at both the testsuite and
-- testcase levels so the caller can always iterate a plain array.
function M.each_testcase(data, fn)
  local root = data.testsuites or data
  local suites = root.testsuite
  if not suites then
    return
  end
  if suites._attr then
    suites = { suites }
  end
  for _, suite in ipairs(suites) do
    local tcs = suite.testcase
    if tcs then
      if tcs._attr then
        tcs = { tcs }
      end
      for _, tc in ipairs(tcs) do
        fn(tc)
      end
    end
  end
end

-- Resolve the testlogs directory for spec.context.target, or nil when no target
-- is set or the label can't be parsed.
-- spec.context fields used: root, testlogs_symlink, target
function M.testlogs_dir(spec)
  local target = spec.context.target
  if not target then
    return nil
  end
  local tpkg, tname = target:match("//([^:]*):(.+)")
  if not tpkg or not tname then
    return nil
  end
  -- tpkg is "" for a root-package target (//:foo); skip it so the path does
  -- not get a doubled slash.
  local base = spec.context.root .. "/" .. spec.context.testlogs_symlink
  return (tpkg == "" and base or (base .. "/" .. tpkg)) .. "/" .. tname
end

-- Call fn(testcase) for every <testcase> across every test.xml under the
-- target's testlogs directory (all shards).  Returns the number of test.xml
-- files processed, or nil when there is no target or no test.xml exists.
--
-- lib.xml.parse (xml2lua) decodes XML entities in attribute values by default
-- (&amp; &lt; &gt; &quot; &apos; and numeric &#nn; / &#xnn; refs), so a
-- <testcase>'s _attr.name/classname arrive un-escaped.  Caveat: numeric refs
-- are decoded only for code points < 256, as a single Latin-1 byte; higher
-- code points are left as the literal reference.  Test-method names are ASCII
-- identifiers, so this doesn't affect matching.  CDATA sections are captured
-- verbatim (not entity-decoded), as they should be.
function M.for_each_testcase(spec, fn)
  local dir = M.testlogs_dir(spec)
  if not dir then
    return nil
  end
  local xml_files = M.find_xml_files(dir)
  if #xml_files == 0 then
    return nil
  end
  for _, xml_path in ipairs(xml_files) do
    local xml = M.read_file(xml_path)
    if xml then
      local ok, data = pcall(lib.xml.parse, xml)
      if ok then
        M.each_testcase(data, fn)
      end
    end
  end
  return #xml_files
end

-- The <failure>/<error> node of a <testcase>, or nil.  xml2lua reduces it to a
-- string when it has body text but no attributes, or a table
-- { _attr = { message = … }, [1] = "body", … } when it has both.
local function fail_node(tc)
  return tc.failure or tc.error
end

-- Concatenate a failure/error node's text body (the traceback), or nil.
local function node_body(node)
  if type(node) == "string" then
    return node
  end
  if type(node) == "table" then
    local parts = {}
    for _, v in ipairs(node) do
      if type(v) == "string" then
        parts[#parts + 1] = v
      end
    end
    if #parts > 0 then
      return table.concat(parts, "\n")
    end
  end
  return nil
end

local function first_nonblank_line(s)
  for line in (s .. "\n"):gmatch("(.-)\n") do
    local t = line:gsub("^%s+", ""):gsub("%s+$", "")
    if t ~= "" then
      return t
    end
  end
  return nil
end

-- A short human-readable message for a failing <testcase>: the failure/error
-- node's `message` attribute, else the first non-blank line of its body.
function M.failure_message(tc)
  local node = fail_node(tc)
  if not node then
    return nil
  end
  if type(node) == "table" and node._attr and node._attr.message and node._attr.message ~= "" then
    return node._attr.message
  end
  local body = node_body(node)
  return body and first_nonblank_line(body)
end

-- The 0-indexed source line of the deepest traceback frame in `filename`
-- (matched by basename), or nil.  JUnit carries no line attribute, so this
-- parses the Python traceback in the failure/error body:
--   File "…/test_foo.py", line 42, in test_bar
local function basename(path)
  return path and path:match("([^/]+)$")
end

function M.failure_line(tc, filename)
  local node = fail_node(tc)
  if not node then
    return nil
  end
  local body = node_body(node)
  local base = basename(filename)
  if not (body and base) then
    return nil
  end
  local last
  for file, lno in body:gmatch('File "([^"]+)", line (%d+)') do
    if basename(file) == base then
      last = tonumber(lno)
    end
  end
  return last and (last - 1) or nil -- traceback is 1-indexed; neotest wants 0
end

return M
