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

		local command_index
		for index, arg in ipairs(last_argv) do
			if arg == "-c" then
				command_index = index
				break
			end
		end
		assert.is_not_nil(command_index)
		assert.same("select 1\nselect 2", last_argv[command_index + 1])
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

	it("keeps insert q searchable and finishes picker cancellation once", function()
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
		local selected_calls = 0
		local wipeout_callback
		local finished = 0
		local selected_service
		package.loaded["telescope.pickers"] = {
			new = function(_, picker_options)
				return {
					find = function()
						picker_options.attach_mappings(1, function(mode, key, callback)
							mappings[mode .. ":" .. key] = callback
						end)
					end,
				}
			end,
		}
		package.loaded["telescope.actions"] = {
			close = function() end,
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
		for _, name in ipairs(module_names) do
			package.loaded[name] = saved_modules[name]
		end

		assert.is_nil(mappings["i:q"])
		assert.truthy(mappings["i:<esc>"])
		assert.truthy(mappings["i:<C-c>"])
		assert.truthy(mappings["n:<esc>"])
		assert.truthy(mappings["n:<C-c>"])
		assert.truthy(mappings["n:q"])
		mappings.select_default()
		assert.same(1, finished)
		assert.is_nil(selected_service)
	end)
end)
