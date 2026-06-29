local lib = require("neotest.lib")

local function read_file(path)
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
local function find_xml_files(dir)
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
      for _, f in ipairs(find_xml_files(full_path)) do
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
local function each_testcase(data, fn)
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

-- Index the position tree neotest hands us so JUnit testcases can be matched
-- to the canonical position IDs assigned at discovery time.  This avoids
-- reconstructing those IDs from the XML, which would hardcode neotest's "::"
-- ID format and the "last classname component is the class" heuristic.
--   by_class_method: "ClassName.test_method" -> position id
--   by_method:       "test_method" -> { position id, ... }
local function index_positions(tree)
  local by_class_method = {}
  local by_method = {}
  for _, node in tree:iter_nodes() do
    local data = node:data()
    if data.type == "test" then
      by_method[data.name] = by_method[data.name] or {}
      table.insert(by_method[data.name], data.id)
      local parent = node:parent()
      if parent and parent:data().type == "namespace" then
        by_class_method[parent:data().name .. "." .. data.name] = data.id
      end
    end
  end
  return by_class_method, by_method
end

-- Map a JUnit <testcase classname=… name=…> to a neotest position ID.
local function find_id(classname, name, by_class_method, by_method)
  -- JUnit classname is dotted (e.g. "pkg.module.ClassName"); the class is its
  -- last component.
  local class = classname and classname:match("([^.]+)$")
  if class then
    local id = by_class_method[class .. "." .. name]
    if id then
      return id
    end
  end
  -- Fall back to the method name when it is unique across the tree (covers
  -- top-level functions, which have no namespace parent).
  local ids = by_method[name]
  if ids and #ids == 1 then
    return ids[1]
  end
  return nil
end

local M = {}

-- Collect test results from JUnit XML files under bazel-testlogs.
--
-- The Bazel target is read from spec.context.target (resolved at build_spec
-- time).  This function locates the testlogs directory for that target and
-- recurses into it collecting every test.xml (handles sharded Bazel targets).
--
-- Each <testcase> is matched back to a position in `tree` (see
-- index_positions / find_id) so results carry neotest's own position IDs.
--
-- spec.context fields used: root, testlogs_symlink, target
--
-- Returns table<position_id, {status}>, or nil when no target is set or no
-- test.xml files exist under the testlogs directory.
function M.collect(spec, result, tree)
  local target = spec.context.target
  if not target then
    return nil
  end

  local tpkg, tname = target:match("//([^:]*):(.+)")
  if not tpkg or not tname then
    return nil
  end

  local testlogs_dir = spec.context.root .. "/" .. spec.context.testlogs_symlink .. "/" .. tpkg .. "/" .. tname

  local xml_files = find_xml_files(testlogs_dir)
  if #xml_files == 0 then
    return nil
  end

  local by_class_method, by_method = index_positions(tree)
  local results = {}

  for _, xml_path in ipairs(xml_files) do
    local xml = read_file(xml_path)
    if xml then
      local ok, data = pcall(lib.xml.parse, xml)
      if ok then
        each_testcase(data, function(tc)
          local attr = tc._attr
          if attr and attr.name then
            local id = find_id(attr.classname, attr.name, by_class_method, by_method)
            if id then
              results[id] = {
                status = (tc.failure or tc.error) and "failed" or tc.skipped and "skipped" or "passed",
              }
            end
          end
        end)
      end
    end
  end

  return not vim.tbl_isempty(results) and results or nil
end

return M
