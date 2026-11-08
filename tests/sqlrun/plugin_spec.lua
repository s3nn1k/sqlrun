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

	it("sweeps from the registered VimEnter autocmd on a real startup in a child nvim", function()
		if vim.fn.executable("nvim") ~= 1 then
			pending("child nvim unavailable")
		end
		local marker = vim.fn.tempname() .. ".markers"
		local child_init = vim.fn.tempname() .. ".lua"
		local child_trigger = vim.fn.tempname() .. ".lua"
		vim.fn.writefile({
			"local marker_path = os.getenv('SQLRUN_TEST_MARKER')",
			"local function record(tag)",
			"	local file = io.open(marker_path, 'a')",
			"	file:write(tag .. ' did_enter=' .. tostring(vim.v.vim_did_enter) .. '\\n')",
			"	file:close()",
			"end",
			"package.loaded['sqlrun'] = {",
			"	sweep = function()",
			"		record('sweep')",
			"	end,",
			"	shutdown = function()",
			"		record('shutdown')",
			"	end,",
			"}",
			"vim.opt.runtimepath:prepend(os.getenv('SQLRUN_TEST_REPO'))",
			"vim.o.swapfile = false",
		}, child_init)
		vim.fn.writefile({
			"local file = io.open(os.getenv('SQLRUN_TEST_MARKER'), 'a')",
			"file:write('trigger did_enter=' .. tostring(vim.v.vim_did_enter) .. '\\n')",
			"file:close()",
			"vim.api.nvim_exec_autocmds('VimEnter', {})",
		}, child_trigger)

		local handle = vim.system(
			{ "nvim", "-n", "--headless", "-u", child_init, "-c", "luafile " .. child_trigger, "+qa" },
			{
				env = { SQLRUN_TEST_MARKER = marker, SQLRUN_TEST_REPO = vim.fs.normalize(vim.fn.getcwd()) },
				text = true,
				timeout = 10000,
			}
		)
		local done = handle:wait()
		local lines = vim.fn.filereadable(marker) == 1 and vim.fn.readfile(marker) or {}
		os.remove(marker)
		os.remove(child_init)
		os.remove(child_trigger)

		assert.equals(0, done.code)
		assert.same(3, #lines)
		assert.truthy(lines[1]:find("^trigger"))
		assert.truthy(lines[2]:find("^sweep"))
		assert.truthy(lines[3]:find("^shutdown"))
	end)
end)
