return {
  {
    "mfussenegger/nvim-lint",
    opts = function(_, opts)
      opts.linters["markdownlint-cli2"] = {
        args = {
          "--config",
          vim.fn.expand("~/.config/markdownlint/.markdownlint.yaml"),
          "-",
        },
      }
    end,
  },
}
