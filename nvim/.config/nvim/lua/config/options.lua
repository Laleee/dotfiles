-- Options are automatically loaded before lazy.nvim startup
-- Default options that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/options.lua
-- Add any additional options here

-- Comfortable defaults for long-running editor and agent sessions.
vim.opt.clipboard = "unnamedplus"
vim.opt.confirm = true
vim.opt.cursorline = true
vim.opt.ignorecase = true
vim.opt.smartcase = true
vim.opt.scrolloff = 8
vim.opt.sidescrolloff = 8
vim.opt.splitbelow = true
vim.opt.splitright = true
vim.opt.updatetime = 250
vim.opt.timeoutlen = 400
vim.opt.undofile = true
vim.opt.signcolumn = "yes"
vim.opt.softtabstop = 2

-- Keep indentation conventional by filetype while using spaces by default.
vim.api.nvim_create_autocmd("FileType", {
  pattern = {
    "markdown",
    "markdown.mdx",
    "yaml",
    "yaml.docker-compose",
    "json",
    "jsonc",
    "javascript",
    "javascriptreact",
    "typescript",
    "typescriptreact",
    "lua",
    "html",
    "css",
    "scss",
    "vue",
  },
  callback = function()
    vim.opt_local.expandtab = true
    vim.opt_local.shiftwidth = 2
    vim.opt_local.softtabstop = 2
    vim.opt_local.tabstop = 2
  end,
})

vim.api.nvim_create_autocmd("FileType", {
  pattern = "python",
  callback = function()
    vim.opt_local.expandtab = true
    vim.opt_local.shiftwidth = 4
    vim.opt_local.softtabstop = 4
    vim.opt_local.tabstop = 4
  end,
})

vim.api.nvim_create_autocmd("FileType", {
  pattern = "make",
  callback = function()
    vim.opt_local.expandtab = false
    vim.opt_local.shiftwidth = 8
    vim.opt_local.softtabstop = 0
    vim.opt_local.tabstop = 8
  end,
})
