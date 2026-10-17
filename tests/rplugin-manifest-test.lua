-- Driver for checks.rplugin-manifest, run as `nvim -u <init.lua> -l this.lua <mode> [args]`.
-- A failed assert makes nvim exit non-zero.
local mode = arg[1]

if mode == "absent" then
  -- --clean, or rplugin disabled: nothing may have been registered
  assert(vim.fn.exists("#FuncUndefined#NvimxRpluginTest") == 0, "the manifest was loaded when it must not be")
  return
end

if mode == "hosts" then
  assert(vim.fn.NvimxRpluginNode() == "node", "the node remote plugin did not answer")
  assert(vim.fn.NvimxRpluginRuby() == "ruby", "the ruby remote plugin did not answer")
  return
end

assert(mode == "run", "unknown mode " .. tostring(mode))
local want, dev = arg[2], arg[3]
assert(vim.fn.NvimxRpluginTest() == want, "NvimxRpluginTest() answered the wrong version")
vim.cmd("NvimxRpluginCmd")
assert(vim.g.nvimx_rplugin_cmd == want, "NvimxRpluginCmd set " .. vim.inspect(vim.g.nvimx_rplugin_cmd))
vim.cmd("doautocmd User NvimxRpluginPing")
-- exactly once: a stale registration would fire a second (or the wrong) handler
assert(vim.deep_equal(vim.g.nvimx_rplugin_ping, { want }), "ping handlers: " .. vim.inspect(vim.g.nvimx_rplugin_ping))
-- the plugin was never put on the rtp by lazy: the manifest alone made it work
local plugin = require("lazy.core.config").plugins["tokyonight.nvim"]
assert(plugin._.loaded == nil, "tokyonight.nvim was loaded; this proves nothing about the manifest")
local messages = vim.fn.execute("messages")
assert(not messages:find("nvimx:", 1, true), "the loader warned: " .. messages)
if dev then
  assert(vim.fn[dev]() == "dev", "the dev plugin registered by the user's manifest stopped answering")
end
