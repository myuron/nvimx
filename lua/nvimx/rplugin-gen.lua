-- Runs under `nvim -l` inside the manifest derivation (nix/lib/rplugin-manifest.nix), and only
-- when something was staged. arg[1] = the staging dir (one subdir per plugin, holding the rplugin/
-- dirs of the hosts that are on), arg[2] = the raw manifest path (= $NVIM_RPLUGIN_MANIFEST).
-- Writes the manifest to stdout, which the derivation appends after its header. Under `-l` only
-- io.stdout reaches stdout (echomsg output such as "remote/host: ... registered plugins" goes to
-- stderr), so host tracebacks and the warnings below stay in the build log.
local stage, raw = arg[1], arg[2]

for _, name in ipairs(vim.fn.readdir(stage)) do
  vim.opt.rtp:append(stage .. "/" .. name)
end
vim.cmd("runtime! plugin/rplugin.vim")
vim.cmd("UpdateRemotePlugins")

-- A plugin whose host cannot load it (a missing Python package, say) is skipped by neovim and the
-- run still succeeds. Say so instead of leaving it out silently. The patterns are the ones
-- runtime/autoload/remote/host.vim passes to remote#host#Register for each host.
local patterns = { python3 = "*", ruby = "*.rb", node = "*" }
local f = assert(io.open(raw, "r"))
local manifest = f:read("*a")
f:close()

-- the host's last message has no trailing newline
io.stderr:write("\n")
local missing = {}
for host, pattern in pairs(patterns) do
  for _, p in ipairs(vim.api.nvim_get_runtime_file("rplugin/" .. host .. "/" .. pattern, true)) do
    local path = vim.fn.resolve(p)
    if not manifest:find(path, 1, true) then
      local plugin = vim.fn.fnamemodify(path, ":h:h:h:t")
      io.stderr:write(
        ("nvimx: %s (%s) did not register with the %s host and is left out of the manifest; see the host error above (a package missing from extraPython3Packages?)\n"):format(
          path,
          plugin,
          host
        )
      )
      table.insert(missing, '" not registered: ' .. path)
    end
  end
end

table.sort(missing)
if #missing > 0 then
  io.stdout:write(table.concat(missing, "\n"), "\n")
end
io.stdout:write(manifest)
