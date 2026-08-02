-- Marker file for checks.dev-plugins: it only has to make dev-root/tokyonight.nvim a real,
-- non-empty directory in the store, so that the dev dir the check asserts on is not merely a
-- string that happens to match. Never sourced: the test spec marks every plugin `lazy = true`.
return {}
