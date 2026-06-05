-- Minimal init used by `make test` / PlenaryBustedDirectory.
-- Puts the plugin and plenary on the runtimepath, nothing else.
local source = debug.getinfo(1, "S").source:sub(2)
local tests_dir = vim.fn.fnamemodify(source, ":p:h")
local root = vim.fn.fnamemodify(tests_dir, ":h")

vim.opt.swapfile = false
vim.opt.rtp:prepend(root)

local function add_if_present(path)
  if vim.fn.isdirectory(path) == 1 then
    vim.opt.rtp:prepend(path)
    return true
  end
  return false
end

-- plenary.nvim (lazy.nvim or packer locations)
local ok = add_if_present(vim.fn.stdpath("data") .. "/lazy/plenary.nvim")
if not ok then
  add_if_present(vim.fn.stdpath("data") .. "/site/pack/packer/start/plenary.nvim")
end

vim.cmd("runtime plugin/plenary.vim")
