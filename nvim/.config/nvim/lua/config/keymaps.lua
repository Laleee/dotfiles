-- Keymaps are automatically loaded on the VeryLazy event
-- Default keymaps that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/keymaps.lua
-- Add any additional keymaps here

local function project_name()
  local cwd = vim.uv.cwd() or vim.fn.getcwd()
  return vim.fn.fnamemodify(cwd, ":t")
end

local function open_terminal(command)
  vim.cmd("botright split")
  vim.cmd("resize 14")
  vim.cmd("terminal " .. command)
  vim.cmd("startinsert")
end

vim.api.nvim_create_user_command("Herdr", function()
  if vim.env.HERDR_ENV == "1" then
    vim.notify("Already inside Herdr; use its panes/tabs for agents and terminals.", vim.log.levels.INFO)
    return
  end
  open_terminal("herdr --session " .. vim.fn.shellescape(project_name()))
end, { desc = "Open this project in a Herdr session" })

vim.api.nvim_create_user_command("HerdrStatus", function()
  open_terminal("herdr status")
end, { desc = "Show Herdr status" })

vim.keymap.set("n", "<leader>th", "<cmd>Herdr<cr>", { desc = "Open Herdr session" })
vim.keymap.set("n", "<leader>ts", "<cmd>HerdrStatus<cr>", { desc = "Herdr status" })
vim.keymap.set("n", "<leader>tt", function()
  open_terminal(vim.o.shell)
end, { desc = "Open terminal" })
