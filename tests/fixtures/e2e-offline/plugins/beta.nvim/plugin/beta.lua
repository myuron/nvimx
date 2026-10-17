vim.api.nvim_create_user_command("BetaHi", function()
  vim.g.nvimx_e2e_beta = require("gamma").value
end, {})
