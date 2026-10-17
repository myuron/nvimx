Neovim.plugin do |plug|
  plug.function(:NvimxRpluginRuby, sync: true) { |nvim| "ruby" }
end
