vim.opt.runtimepath:prepend(vim.fn.getcwd())
local plenary = os.getenv("SQLRUN_PLENARY")
if not plenary or plenary == "" then
	plenary = vim.fs.joinpath(vim.fn.stdpath("data"), "lazy", "plenary.nvim")
end
vim.opt.runtimepath:append(plenary)
vim.o.swapfile = false
