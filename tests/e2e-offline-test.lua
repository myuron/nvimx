-- Driver of checks.e2e-offline step 2, run inside the wrapped nvim as
-- `nvim --headless -c "luafile <this>"` with the user's init.lua already executed. The farm
-- is read from $FARM and the success marker is written to $PROBE_OK: an error in a -c command
-- alone does not make headless nvim exit non-zero, so the shell checks the marker too.
local function run()
  local farm = assert(os.getenv("FARM"), "FARM unset")
  assert(vim.v.errmsg == "", "startup raised: " .. vim.v.errmsg)
  assert(vim.g.nvimx_e2e_alpha == true, "the startup plugin was not sourced")

  local plugins = require("lazy.core.config").plugins
  local names = vim.tbl_keys(plugins)
  table.sort(names)
  assert(
    vim.deep_equal(names, { "alpha.nvim", "beta.nvim", "gamma.nvim", "lazy.nvim" }),
    "unexpected plugin set: " .. table.concat(names, ",")
  )

  -- beta is lazy (cmd): not loaded until :BetaHi, which also pulls gamma in as a dependency.
  assert(not plugins["beta.nvim"]._.loaded, "beta.nvim loaded before :BetaHi")
  vim.cmd("BetaHi")
  assert(vim.g.nvimx_e2e_beta == 42, "BetaHi did not reach gamma through the dependency")

  local data = vim.fn.stdpath("data")
  for name, p in pairs(plugins) do
    assert(p._.loaded, name .. " is not loaded")
    local real = vim.uv.fs_realpath(p.dir)
    assert(real and vim.startswith(real, "/nix/store/"), name .. " is not in the store: " .. tostring(real))
    if name == "lazy.nvim" then
      -- lazy's own entry is not a spec: its dir is the bootstrap symlink into the farm.
      assert(real == vim.uv.fs_realpath(farm .. "/lazy.nvim"), "lazy.nvim does not come from the farm")
    else
      assert(p._.is_local, name .. " is not local")
      assert(p.dir == farm .. "/" .. name, name .. " dir is " .. tostring(p.dir))
      assert(not vim.uv.fs_stat(data .. "/lazy/" .. name), name .. " was cloned")
    end
  end
end

local ok, err = pcall(run)
if ok then
  local f = assert(io.open(assert(os.getenv("PROBE_OK")), "w"))
  f:write("ok\n")
  f:close()
  vim.cmd("qa!")
else
  io.stderr:write("e2e-offline probe failed: " .. tostring(err) .. "\n")
  vim.cmd("cquit 1")
end
