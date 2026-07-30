-- All of nvimx's lua runs inside neovim (LuaJIT).
std = "luajit"

-- `globals` rather than `read_globals`: config lua legitimately writes fields on vim
-- (e.g. vim.g.mapleader = " "), which read_globals would flag as "setting read-only field".
globals = { "vim" }

-- `arg` (from `nvim -l`, used by resolve.lua / genflake.lua) is one of luacheck's standard
-- globals regardless of `std`, so it needs no declaration here.

-- Line width is stylua's job (column_width in stylua.toml). Keeping a second limit here
-- would deadlock `nix fmt`: stylua only wraps where it safely can, so a line it considers
-- finished could still fail a luacheck line-length check with no way to satisfy both.
max_line_length = false

-- lua/nvimx/bootstrap.lua.in does not match `*.lua`, so treefmt already excludes it from both
-- stylua and luacheck without needing an explicit exclude_files entry.
