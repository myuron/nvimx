-- lazy = true with no trigger: the plugin is never loaded, so a remote plugin that answers anyway
-- was registered by the build-time manifest and not by lazy putting the plugin on the rtp.
-- No clone snippet: the bootstrap puts the farm's lazy.nvim in front.
require("lazy").setup({ { "folke/tokyonight.nvim", lazy = true } })
