local sqlrun = require("sqlrun.init")

local tmp_root
local notify_calls
local last_argv
local last_opts
local last_exit_callback
local spawn_should_throw
local original_system
local original_notify
local original_pick_service
local original_pgservicefile

local function restore_pgservicefile()
	if original_pgservicefile == vim.NIL then
		vim.env.PGSERVICEFILE = nil
	else
		vim.fn.setenv("PGSERVICEFILE", original_pgservicefile)
	end
end

local function write_file(rel_path, lines)
	local full = tmp_root .. "/" .. rel_path
	vim.fn.mkdir(vim.fs.dirname(full), "p")
	vim.fn.writefile(lines, full)
	return full
end

local function stub_system()
	original_system = vim.system
	last_argv = nil
	last_opts = nil
	last_exit_callback = nil
	vim.system = function(argv, opts, on_exit)
		if spawn_should_throw then
			error("spawn failed: enoent")
		end
		last_argv = argv
		last_opts = opts
		last_exit_callback = on_exit
		return { pid = 424242 }
	end
end

local function cleanup_result()
	local buf = vim.fn.bufnr("sqlrun://result")
	if buf > 0 then
		for _, win in ipairs(vim.fn.win_findbuf(buf)) do
			pcall(vim.api.nvim_win_close, win, true)
		end
		pcall(vim.api.nvim_buf_delete, buf, { force = true })
	end
end

local function result_header()
	local buf = vim.fn.bufnr("sqlrun://result")
	if buf < 0 then
		return nil
	end
	return vim.fn.getbufline(buf, 1)[1]
end

local function spawned_inline_command()
	for index, arg in ipairs(last_argv) do
		if arg == "-c" then
			return last_argv[index + 1]
		end
	end
	return nil
end

local function spawns_file()
	return vim.tbl_contains(last_argv, "-f")
end

local function drain_scheduled_events()
	vim.wait(100, function()
		return false
	end, 1)
end

local function capture_run_events()
	local event_log = {}
	vim.api.nvim_create_augroup("SqlrunRunEvents", { clear = true })
	for _, pattern in ipairs({ "SqlrunRunStart", "SqlrunRunDone" }) do
		vim.api.nvim_create_autocmd("User", {
			group = "SqlrunRunEvents",
			pattern = pattern,
			callback = function()
				table.insert(event_log, { pattern = pattern, status = vim.g.sqlrun_last_status })
			end,
		})
	end
	return event_log
end

local function feed_keys(keys)
	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "mx", false)
end

local function stub_telescope(prompt_bufnr, close)
	local module_names = {
		"telescope.pickers",
		"telescope.actions",
		"telescope.actions.state",
		"telescope.finders",
		"telescope.config",
	}
	local saved_modules = {}
	for _, name in ipairs(module_names) do
		saved_modules[name] = package.loaded[name]
	end
	local mappings = {}
	package.loaded["telescope.pickers"] = {
		new = function(_, picker_options)
			return {
				find = function()
					picker_options.attach_mappings(prompt_bufnr, function(mode, key, callback)
						mappings[mode .. ":" .. key] = callback
					end)
				end,
			}
		end,
	}
	package.loaded["telescope.actions"] = {
		close = close,
		select_default = {
			replace = function(_, callback)
				mappings.select_default = callback
			end,
		},
	}
	package.loaded["telescope.actions.state"] = {
		get_selected_entry = function()
			return { value = "svc" }
		end,
	}
	package.loaded["telescope.finders"] = {
		new_table = function(options)
			return options
		end,
	}
	package.loaded["telescope.config"] = {
		values = {
			generic_sorter = function()
				return {}
			end,
		},
	}
	local function restore()
		for _, name in ipairs(module_names) do
			package.loaded[name] = saved_modules[name]
		end
	end
	return mappings, restore
end

local function run_select_mode_selection(keys, expected_mode, expected_text)
	vim.g.sqlrun_service = nil
	vim.b.sqlrun_service = nil
	stub_system()
	sqlrun.pick_service = function(callback)
		callback("svc")
	end
	local file = write_file("sel-mode.sql", { "select 1", "select 2" })
	vim.cmd("edit " .. vim.fn.fnameescape(file))
	vim.api.nvim_win_set_cursor(0, { 1, 0 })
	feed_keys(keys)
	assert.same(expected_mode, vim.fn.mode())

	sqlrun.run()

	assert.is_false(spawns_file())
	assert.same(expected_text, spawned_inline_command())
	last_exit_callback({ code = 0, stdout = "", stderr = "" })
end

describe("run", function()
	before_each(function()
		tmp_root = vim.fs.normalize(vim.fn.tempname())
		vim.fn.mkdir(tmp_root, "p")
		notify_calls = {}
		spawn_should_throw = false
		original_notify = vim.notify
		vim.notify = function(message, level)
			table.insert(notify_calls, { message = message, level = level })
		end
		sqlrun.setup({
			pg_service_path = tmp_root .. "/pg_service.conf",
			connections_path = tmp_root .. "/missing-connections.toml",
		})
		write_file("pg_service.conf", { "[svc]", "port=15432" })
		original_pick_service = sqlrun.pick_service
		original_pgservicefile = vim.fn.getenv("PGSERVICEFILE")
		vim.g.sqlrun_service = "stale-global"
		vim.b.sqlrun_service = "stale-buffer"
	end)

	after_each(function()
		vim.system = original_system
		vim.notify = original_notify
		sqlrun.pick_service = original_pick_service
		restore_pgservicefile()
		vim.g.sqlrun_service = nil
		vim.b.sqlrun_service = nil
		vim.g.sqlrun_last_status = nil
		pcall(vim.api.nvim_del_augroup_by_name, "SqlrunRunEvents")
		cleanup_result()
		vim.fn.delete(tmp_root, "rf")
	end)

	it("saves a modified buffer before running the file", function()
		stub_system()
		local picker_calls = 0
		sqlrun.pick_service = function(callback)
			picker_calls = picker_calls + 1
			callback("svc")
		end
		local file = write_file("q.sql", { "select 1" })
		vim.cmd("edit " .. vim.fn.fnameescape(file))
		vim.api.nvim_buf_set_lines(0, 0, -1, false, { "select 2" })
		assert.is_true(vim.bo.modified)

		sqlrun.run()

		assert.is_false(vim.bo.modified)
		assert.same(1, picker_calls)
		assert.same("psql", last_argv[1])
		assert.truthy(vim.tbl_contains(last_argv, "-f"))
		assert.truthy(vim.tbl_contains(last_argv, file))
		assert.same({ PGSERVICEFILE = vim.fs.normalize(tmp_root .. "/pg_service.conf") }, last_opts.env)
		last_exit_callback({ code = 0, stdout = "2\n", stderr = "" })
		assert.is_true(vim.wait(500, function()
			local header = result_header()
			return header ~= nil and header:find("status: ok") ~= nil
		end))
	end)

	it("resets the busy guard when psql cannot be spawned", function()
		stub_system()
		sqlrun.pick_service = function(callback)
			callback("svc")
		end
		spawn_should_throw = true
		local file = write_file("q2.sql", { "select 1" })
		vim.cmd("edit " .. vim.fn.fnameescape(file))

		sqlrun.run()

		local errors = vim.tbl_filter(function(call)
			return call.level == vim.log.levels.ERROR
		end, notify_calls)
		assert.same(1, #errors)
		assert.truthy(errors[1].message:find("cannot run psql"))

		sqlrun.run()

		local warnings = vim.tbl_filter(function(call)
			return call.level == vim.log.levels.WARN
		end, notify_calls)
		assert.same({}, warnings)
	end)

	it("resets running when the picker cannot open", function()
		local telescope_path = vim.fs.normalize(vim.fn.stdpath("data") .. "/lazy/telescope.nvim")
		local had_telescope = vim.list_contains(vim.opt.runtimepath:get(), telescope_path)
		if had_telescope then
			vim.opt.runtimepath:remove(telescope_path)
		end
		stub_system()
		local file = write_file("q3.sql", { "select 1" })
		vim.cmd("edit " .. vim.fn.fnameescape(file))

		sqlrun.run()
		sqlrun.run()

		if had_telescope then
			vim.opt.runtimepath:append(telescope_path)
		end
		local busy = vim.tbl_filter(function(call)
			return call.level == vim.log.levels.WARN and call.message:find("already running", 1, true) ~= nil
		end, notify_calls)
		assert.same({}, busy)
		local errors = vim.tbl_filter(function(call)
			return call.level == vim.log.levels.ERROR and call.message:find("telescope", 1, true) ~= nil
		end, notify_calls)
		assert.same(2, #errors)
	end)

	it("opens the picker for every run despite stale service variables", function()
		stub_system()
		local picker_calls = 0
		sqlrun.pick_service = function(callback)
			picker_calls = picker_calls + 1
			callback("svc")
		end
		local file = write_file("q4.sql", { "select 1" })
		vim.cmd("edit " .. vim.fn.fnameescape(file))

		sqlrun.run()
		last_exit_callback({ code = 0, stdout = "", stderr = "" })
		sqlrun.run()
		last_exit_callback({ code = 0, stdout = "", stderr = "" })

		assert.same(2, picker_calls)
	end)

	it("does not spawn when the picker is cancelled", function()
		stub_system()
		local picker_calls = 0
		sqlrun.pick_service = function(callback)
			picker_calls = picker_calls + 1
			callback(nil)
		end
		local file = write_file("q5.sql", { "select 1" })
		vim.cmd("edit " .. vim.fn.fnameescape(file))

		sqlrun.run()
		sqlrun.run()

		assert.same(2, picker_calls)
		assert.is_nil(last_argv)
		local busy = vim.tbl_filter(function(call)
			return call.level == vim.log.levels.WARN and call.message:find("already running", 1, true) ~= nil
		end, notify_calls)
		assert.same({}, busy)
	end)

	it("uses the visual selection captured before the picker changes buffers", function()
		stub_system()
		sqlrun.pick_service = function(callback)
			local other = vim.api.nvim_create_buf(false, true)
			vim.api.nvim_buf_set_lines(other, 0, -1, false, { "select wrong" })
			vim.api.nvim_set_current_buf(other)
			callback("svc")
		end
		local file = write_file("selection.sql", { "select 1", "select 2" })
		vim.cmd("edit " .. vim.fn.fnameescape(file))
		vim.api.nvim_win_set_cursor(0, { 1, 0 })
		vim.cmd("normal! Vj")
		assert.truthy(vim.fn.mode():find("^V"))

		sqlrun.run()

		assert.is_false(spawns_file())
		assert.same("select 1\nselect 2", spawned_inline_command())
		last_exit_callback({ code = 0, stdout = "", stderr = "" })
	end)

	it("uses the configured service file instead of ambient PGSERVICEFILE", function()
		stub_system()
		vim.fn.setenv("PGSERVICEFILE", tmp_root .. "/ambient.conf")
		sqlrun.setup({
			pg_service_path = tmp_root .. "/selected.conf",
			connections_path = tmp_root .. "/missing-connections.toml",
		})
		write_file("selected.conf", { "[svc]", "port=15432" })
		sqlrun.pick_service = function(callback)
			callback("svc")
		end
		local file = write_file("q6.sql", { "select 1" })
		vim.cmd("edit " .. vim.fn.fnameescape(file))

		sqlrun.run()

		assert.same({ PGSERVICEFILE = vim.fs.normalize(tmp_root .. "/selected.conf") }, last_opts.env)
		last_exit_callback({ code = 0, stdout = "", stderr = "" })
	end)

	it("runs linewise, charwise and blockwise select-mode selections instead of the file", function()
		run_select_mode_selection("gH", "S", "select 1")
		run_select_mode_selection("gh<End>", "s", "select 1")
		run_select_mode_selection("g<C-H>", "\19", "s")
	end)

	it("keeps insert q searchable and finishes picker cancellation once", function()
		local mappings, restore_telescope = stub_telescope(1, function() end)
		local wipeout_callback
		local finished = 0
		local selected_service
		local original_autocmd = vim.api.nvim_create_autocmd
		vim.api.nvim_create_autocmd = function(_, options)
			wipeout_callback = options.callback
		end

		sqlrun.pick_service(function(service)
			finished = finished + 1
			selected_service = service
		end)
		mappings["n:q"]()
		wipeout_callback()
		vim.api.nvim_create_autocmd = original_autocmd
		mappings.select_default()
		restore_telescope()

		assert.is_nil(mappings["i:q"])
		assert.truthy(mappings["i:<esc>"])
		assert.truthy(mappings["i:<C-c>"])
		assert.truthy(mappings["n:<esc>"])
		assert.truthy(mappings["n:<C-c>"])
		assert.truthy(mappings["n:q"])
		assert.same(1, finished)
		assert.is_nil(selected_service)
	end)

	it("emits SqlrunRunStart before psql and SqlrunRunDone with ok status", function()
		drain_scheduled_events()
		stub_system()
		local event_log = capture_run_events()
		local spawn_marker
		local stubbed_system = vim.system
		vim.system = function(argv, opts, on_exit)
			spawn_marker = #event_log
			return stubbed_system(argv, opts, on_exit)
		end
		sqlrun.pick_service = function(callback)
			callback("svc")
		end
		local file = write_file("q8.sql", { "select 1" })
		vim.cmd("edit " .. vim.fn.fnameescape(file))

		sqlrun.run()

		assert.same(1, #event_log)
		assert.equals("SqlrunRunStart", event_log[1].pattern)
		assert.equals(1, spawn_marker)

		last_exit_callback({ code = 0, stdout = "2\n", stderr = "" })

		assert.is_true(vim.wait(500, function()
			return #event_log == 2
		end))
		assert.equals("SqlrunRunDone", event_log[2].pattern)
		assert.equals("ok", event_log[2].status)
		assert.equals("ok", vim.g.sqlrun_last_status)
	end)

	it("marks SqlrunRunDone as error on a failing psql exit", function()
		drain_scheduled_events()
		stub_system()
		local event_log = capture_run_events()
		sqlrun.pick_service = function(callback)
			callback("svc")
		end
		local file = write_file("q9.sql", { "select 1" })
		vim.cmd("edit " .. vim.fn.fnameescape(file))

		sqlrun.run()

		last_exit_callback({ code = 2, stdout = "", stderr = "boom\n" })

		assert.is_true(vim.wait(500, function()
			return #event_log == 2
		end))
		assert.equals("SqlrunRunDone", event_log[2].pattern)
		assert.equals("error", event_log[2].status)
		assert.equals("error", vim.g.sqlrun_last_status)
	end)

	it("delivers the selection when closing wipes the prompt buffer synchronously", function()
		vim.g.sqlrun_service = nil
		vim.b.sqlrun_service = nil
		local prompt_bufnr = vim.api.nvim_create_buf(false, true)
		local mappings, restore_telescope = stub_telescope(prompt_bufnr, function(bufnr)
			vim.api.nvim_buf_delete(bufnr, { force = true })
		end)
		stub_system()
		local file = write_file("q7.sql", { "select 1" })
		vim.cmd("edit " .. vim.fn.fnameescape(file))

		sqlrun.run()
		mappings.select_default()
		restore_telescope()

		assert.same("psql", last_argv[1])
		assert.truthy(vim.tbl_contains(last_argv, "service=svc"))
		assert.truthy(vim.tbl_contains(last_argv, "-f"))
		assert.truthy(vim.tbl_contains(last_argv, file))
		assert.equal(0, vim.fn.bufexists(prompt_bufnr))
		last_exit_callback({ code = 0, stdout = "", stderr = "" })
	end)
end)

describe("setup", function()
	local original_notify_once
	local warned

	before_each(function()
		original_notify_once = vim.notify_once
		warned = {}
		vim.notify_once = function(message, level)
			table.insert(warned, { message = message, level = level })
		end
	end)

	after_each(function()
		vim.notify_once = original_notify_once
	end)

	it("tolerates nil opts", function()
		sqlrun.setup(nil)
		assert.same({}, warned)
	end)

	it("accepts the four known keys with correct types", function()
		sqlrun.setup({
			pg_service_path = "/tmp/pg.conf",
			connections_path = "/tmp/connections.toml",
			max_lines = 100,
			probe_timeout_ms = 1000,
		})
		assert.same({}, warned)
	end)

	it("rejects a wrong type loudly", function()
		local ok, err = pcall(sqlrun.setup, { max_lines = "many" })
		assert.is_false(ok)
		assert.truthy(err:find("max_lines", 1, true))
		assert.same({}, warned)
	end)

	it("warns once on unknown keys", function()
		sqlrun.setup({ max_lines = 10, unknown_key = true })
		assert.equals(1, #warned)
		assert.truthy(warned[1].message:find("unknown_key", 1, true))
		assert.truthy(warned[1].message:find("^sqlrun:"))
		assert.equals(vim.log.levels.WARN, warned[1].level)
	end)
end)
