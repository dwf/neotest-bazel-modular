local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
vim.opt.rtp:prepend(plugin_root)

-- Plenary's busted child processes load test files with a custom runner that
-- does not go through Neovim's rtp-based require searcher.  Mirror every rtp
-- lua/ directory into package.path so that standard Lua require still finds
-- all plugin modules (neotest.lib, nio, etc.).
for _, rtp_dir in ipairs(vim.api.nvim_list_runtime_paths()) do
  local lua_dir = rtp_dir .. "/lua"
  if vim.fn.isdirectory(lua_dir) == 1 then
    package.path = lua_dir .. "/?.lua;" .. lua_dir .. "/?/init.lua;" .. package.path
  end
end
