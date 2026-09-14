---@diagnostic disable: undefined-global
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)
vim.opt.rtp:prepend(vim.env.PLENARY_PATH or root .. "/deps/plenary.nvim")
