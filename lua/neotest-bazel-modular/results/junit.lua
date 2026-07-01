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

return M
