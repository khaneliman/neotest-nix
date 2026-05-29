vim.opt.runtimepath:prepend(vim.fn.getcwd())

local test_rtp = vim.env.NEOTEST_NIX_TEST_RTP or ""
for path in test_rtp:gmatch("[^:]+") do
  vim.opt.runtimepath:append(path)

  local parser = vim.fs.joinpath(path, "parser", "nix.so")
  if vim.loop.fs_stat(parser) ~= nil then
    pcall(vim.treesitter.language.add, "nix", { path = parser })
  end
end
