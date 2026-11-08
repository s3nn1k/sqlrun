if vim.g.sqlrun_disable_auto then
	return
end

if vim.g.sqlrun_did_load then
	return
end
vim.g.sqlrun_did_load = true

local group = vim.api.nvim_create_augroup("SqlrunAutoLifecycle", { clear = true })

if vim.v.vim_did_enter == 1 then
	require("sqlrun").sweep()
else
	vim.api.nvim_create_autocmd("VimEnter", {
		group = group,
		callback = function()
			require("sqlrun").sweep()
		end,
	})
end

vim.api.nvim_create_autocmd("VimLeavePre", {
	group = group,
	callback = function()
		require("sqlrun").shutdown()
	end,
})
