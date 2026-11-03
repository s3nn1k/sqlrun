local sqlrun = require("sqlrun.init")

local tmp_root
local notify_calls
local last_argv
local last_exit_callback
local spawn_should_throw
local original_system
local original_notify

local function write_file(rel_path, lines)
	local full = tmp_root .. "/" .. rel_path
	vim.fn.mkdir(vim.fs.dirname(full), "p")
	vim.fn.writefile(lines, full)
	return full
end

local function stub_system()
	original_system = vim.system
	last_argv = nil
	last_exit_callback = nil
	vim.system = function(argv, opts, on_exit)
		if spawn_should_throw then
			error("spawn failed: enoent")
		end
		last_argv = argv
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
		vim.g.sqlrun_service = "svc"
		vim.b.sqlrun_service = nil
	end)

	after_each(function()
		vim.system = original_system
		vim.notify = original_notify
		vim.g.sqlrun_service = nil
		vim.b.sqlrun_service = nil
		cleanup_result()
		vim.fn.delete(tmp_root, "rf")
	end)

	it("saves a modified buffer before running the file", function()
		stub_system()
		local file = write_file("q.sql", { "select 1" })
		vim.cmd("edit " .. vim.fn.fnameescape(file))
		vim.api.nvim_buf_set_lines(0, 0, -1, false, { "select 2" })
		assert.is_true(vim.bo.modified)

		sqlrun.run()

		assert.is_false(vim.bo.modified)
		assert.same("psql", last_argv[1])
		assert.truthy(vim.tbl_contains(last_argv, "-f"))
		assert.truthy(vim.tbl_contains(last_argv, file))
		last_exit_callback({ code = 0, stdout = "2\n", stderr = "" })
		assert.is_true(vim.wait(500, function()
			local header = result_header()
			return header ~= nil and header:find("status: ok") ~= nil
		end))
	end)

	it("resets the busy guard when psql cannot be spawned", function()
		stub_system()
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
end)
