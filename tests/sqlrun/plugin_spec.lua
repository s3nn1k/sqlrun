local plugin_path = vim.fs.joinpath(vim.fn.getcwd(), "plugin", "sqlrun.lua")

local function reset_entry_state()
	vim.g.sqlrun_did_load = nil
	pcall(vim.api.nvim_clear_autocmds, { group = "SqlrunAutoLifecycle" })
end

local function load_entry()
	local chunk = loadfile(plugin_path)
	assert.is_truthy(chunk)
	chunk()
end

local function lifecycle_autocmds(event)
	local found, autocmds = pcall(vim.api.nvim_get_autocmds, { group = "SqlrunAutoLifecycle" })
	if not found then
		return {}
	end
	return vim.tbl_filter(function(autocmd)
		return autocmd.event == event
	end, autocmds)
end

describe("plugin entry", function()
	local real_module
	local counters

	before_each(function()
		counters = { sweeps = 0, shutdowns = 0 }
		real_module = package.loaded["sqlrun"]
		package.loaded["sqlrun"] = {
			sweep = function()
				counters.sweeps = counters.sweeps + 1
			end,
			shutdown = function()
				counters.shutdowns = counters.shutdowns + 1
			end,
		}
	end)

	after_each(function()
		package.loaded["sqlrun"] = real_module
		vim.g.sqlrun_disable_auto = nil
		reset_entry_state()
	end)

	it("stays inert when vim.g.sqlrun_disable_auto is set", function()
		reset_entry_state()
		vim.g.sqlrun_disable_auto = 1

		load_entry()

		assert.equals(0, #lifecycle_autocmds("VimEnter") + #lifecycle_autocmds("VimLeavePre"))
		assert.is_nil(vim.g.sqlrun_did_load)
		assert.same({ sweeps = 0, shutdowns = 0 }, counters)
	end)

	it("registers the lifecycle once and keeps a double load idempotent", function()
		reset_entry_state()

		load_entry()

		assert.equals(1, #lifecycle_autocmds("VimLeavePre"))
		if vim.v.vim_did_enter == 1 then
			assert.same(1, counters.sweeps)
			assert.equals(0, #lifecycle_autocmds("VimEnter"))
		else
			assert.equals(1, #lifecycle_autocmds("VimEnter"))
			assert.same(0, counters.sweeps)
		end

		load_entry()

		assert.equals(1, #lifecycle_autocmds("VimLeavePre"))
		if vim.v.vim_did_enter == 1 then
			assert.same(1, counters.sweeps)
		else
			assert.equals(1, #lifecycle_autocmds("VimEnter"))
		end
		assert.same(0, counters.shutdowns)
	end)
end)
