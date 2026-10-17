-- Loads nvimx's build-time remote-plugin manifest right after runtime/plugin/rplugin.vim (#85).
-- dofile'd from the provider rc (nvimx-providers.lua) with
--   { manifest = "<store path>", hosts = { "python3", ... }, store = "/nix/store/" }
--
-- The user's own manifest (stdpath("data")/rplugin.vim, what :UpdateRemotePlugins writes) is still
-- read by runtime. Ours goes after it, and first every store-path registration of a host we
-- generated is dropped, because a stale one wins even when ours is sourced later:
--   - upstream remote#host#RegisterPlugin throws on a path registered twice (nixpkgs' patch turns
--     the throw into a return), which would abort the rest of the user's file if ours went first;
--   - pynvim imports plugin modules by basename, in registration order, so an old plugin version
--     that is still in the store (or the same one) wins the module name and answers with old code;
--   - a stale autocmd spec points at a handler that the new host never registered
--     ("no request handler registered"), so the new handler never runs.
-- Functions and commands would be redefined by the later registration, which is why only the
-- three above need the removal. Registrations from outside the store (dev plugins) stay.
return function(opts)
  -- runtime's rplugin.vim `finish`es early when g:loaded_remote_plugins exists, but SourcePost
  -- still fires after that; without this, a user who disabled rplugin that way would get it
  -- switched back on. SourcePre sees the variable before the file runs.
  local disabled_before = false
  local pre = vim.api.nvim_create_autocmd("SourcePre", {
    pattern = "*/plugin/rplugin.vim",
    callback = function()
      disabled_before = vim.g.loaded_remote_plugins ~= nil
    end,
  })
  vim.api.nvim_create_autocmd("SourcePost", {
    pattern = "*/plugin/rplugin.vim",
    -- Not `once`: a plugin shipping its own plugin/rplugin.vim and sourced earlier must not use
    -- the hook up. Returning true removes it after the real one has run.
    callback = function()
      if disabled_before then
        pcall(vim.api.nvim_del_autocmd, pre)
        return true
      end
      -- not runtime's rplugin.vim (that one sets this variable)
      if vim.g.loaded_remote_plugins == nil then
        return
      end
      -- runtime skips its manifest with --clean; so do we
      if vim.tbl_contains(vim.v.argv, "--clean") then
        pcall(vim.api.nvim_del_autocmd, pre)
        return true
      end
      for _, host in ipairs(opts.hosts) do
        local needle = 'Bootstrap("' .. host .. '", "' .. opts.store
        -- PluginsForHost returns the live list, so filter() edits it in place. A lambda with
        -- vim.fn.string() arguments, not a string expression: nested quotes broke that one.
        vim.cmd(
          ("call filter(remote#host#PluginsForHost(%s), {_, p -> stridx(p.path, %s) != 0})"):format(
            vim.fn.string(host),
            vim.fn.string(opts.store)
          )
        )
        for _, au in ipairs(vim.api.nvim_get_autocmds({})) do
          -- Vimscript-defined autocmds have no id, so nvim_del_autocmd cannot remove them: clear
          -- their RPC_DEFINE_AUTOCMD_GROUP_* group instead.
          if au.command and au.command:find(needle, 1, true) and au.group then
            vim.api.nvim_clear_autocmds({ group = au.group })
            pcall(vim.api.nvim_del_augroup_by_id, au.group)
          end
        end
        for name, cmd in pairs(vim.api.nvim_get_commands({ builtin = false })) do
          if cmd.definition:find(needle, 1, true) then
            vim.api.nvim_del_user_command(name)
          end
        end
      end
      -- pcall: sourcing throws if init.lua started a host before lazy.setup ("already running")
      local ok, err = pcall(vim.cmd.source, vim.fn.fnameescape(opts.manifest))
      if not ok then
        vim.notify("nvimx: " .. err, vim.log.levels.WARN)
      end
      pcall(vim.api.nvim_del_autocmd, pre)
      return true -- delete this autocmd
    end,
  })
end
