local forward = require("sqlrun.forward")

local registry_root
local real_registry_root
local pid_dir

local function owner_file(service)
	return registry_root .. "/" .. service
end

local function real_owner_file(service)
	return real_registry_root .. "/" .. service
end

local function process_exists(pid)
	local stat = io.open("/proc/" .. tostring(pid) .. "/stat", "r")
	if not stat then
		return false
	end
	stat:close()
	return true
end

local function expected_starttime(pid)
	local stat = io.open("/proc/" .. tostring(pid) .. "/stat", "r")
	local content = stat:read("*a")
	stat:close()
	local last_close = 0
	for index = 1, #content do
		if content:sub(index, index) == ")" then
			last_close = index
		end
	end
	local fields = vim.split(vim.trim(content:sub(last_close + 1)), "%s+")
	local comm_last_field = 2
	local starttime_field = 22
	return fields[starttime_field - comm_last_field]
end

local function capture_notifications(level)
	local captured = {}
	local original_notify = vim.notify
	vim.notify = function(message, message_level)
		if message_level == level then
			table.insert(captured, message)
		end
	end
	return captured, original_notify
end

local function warn_present(warns, needle)
	for _, message in ipairs(warns) do
		if message:find(needle, 1, true) then
			return true
		end
	end
	return false
end

local function rewrite_record(service, line_index, value)
	local lines = vim.fn.readfile(owner_file(service))
	lines[line_index] = value
	vim.fn.writefile(lines, owner_file(service))
end

local function cmdline_of(pid)
	local file = io.open("/proc/" .. pid .. "/cmdline", "r")
	if not file then
		return nil
	end
	local content = file:read("*a")
	file:close()
	return (content:gsub("%z", " "))
end

local function any_process_with_cmdline(prefix)
	for _, entry in ipairs(vim.fn.readdir("/proc")) do
		if tonumber(entry) then
			local cmdline = cmdline_of(entry)
			if cmdline and cmdline:sub(1, #prefix) == prefix then
				return entry
			end
		end
	end
	return nil
end

local function free_port()
	local server = vim.uv.new_tcp()
	server:bind("127.0.0.1", 0)
	local bound = server:getsockname()
	server:close()
	return bound.port
end

local function listener_pre_cmd(pid_path, port, bind_delay_seconds)
	return "python3 -c \"import os,time,socket; f=open('"
		.. pid_path
		.. "','w'); f.write(str(os.getpid())); f.close(); time.sleep("
		.. bind_delay_seconds
		.. "); s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(('127.0.0.1', "
		.. port
		.. ')); s.listen(1); time.sleep(30)"'
end

describe("owner protocol", function()
	before_each(function()
		registry_root = vim.fs.normalize(vim.fn.tempname())
		vim.fn.mkdir(registry_root, "p")
	end)

	after_each(function()
		vim.fn.delete(registry_root, "rf")
	end)

	it("writes a four line record atomically and reads it back", function()
		assert.is_nil(forward.write_owner("svc", vim.uv.getpid(), registry_root))
		local owner_pid, owner_start, forward_pid, forward_start = forward.read_owner("svc", registry_root)
		assert.same(vim.uv.getpid(), owner_pid)
		assert.truthy(owner_start ~= "")
		assert.same(vim.uv.getpid(), forward_pid)
		assert.truthy(forward_start ~= "")
		assert.is_false(vim.fn.filereadable(owner_file("svc") .. ".tmp") == 1)
	end)

	it("reports the owner alive while the identity matches", function()
		forward.write_owner("svc", 4242, registry_root)
		assert.is_true(forward.owner_alive("svc", registry_root))
	end)

	it("reports the owner dead when the recorded identity changes", function()
		forward.write_owner("svc", 4242, registry_root)
		rewrite_record("svc", 2, "bogus-start")
		assert.is_false(forward.owner_alive("svc", registry_root))
	end)

	it("reports the owner dead without a record", function()
		assert.is_false(forward.owner_alive("svc", registry_root))
	end)

	it("kills the recorded forward when the identity matches", function()
		local handle = vim.system({ "sleep", "30" }, { text = true })
		forward.write_owner("svc", handle.pid, registry_root)
		assert.is_nil(forward.remove_forward("svc", registry_root))
		assert.is_true(vim.wait(2000, function()
			return not process_exists(handle.pid)
		end))
		assert.is_false(vim.fn.filereadable(owner_file("svc")) == 1)
	end)

	it("does not kill a recycled pid and warns on identity mismatch", function()
		local handle = vim.system({ "sleep", "30" }, { text = true })
		forward.write_owner("svc", handle.pid, registry_root)
		rewrite_record("svc", 4, "99999999")
		local warns, original_notify = capture_notifications(vim.log.levels.WARN)
		assert.is_nil(forward.remove_forward("svc", registry_root))
		vim.notify = original_notify
		assert.truthy(warns[1]:find("changed identity"))
		assert.is_true(process_exists(handle.pid))
		assert.is_false(vim.fn.filereadable(owner_file("svc")) == 1)
		handle:kill()
	end)

	it("drops a record whose forward process is gone", function()
		forward.write_owner("svc", 999999999, registry_root)
		local warns, original_notify = capture_notifications(vim.log.levels.WARN)
		assert.is_nil(forward.remove_forward("svc", registry_root))
		vim.notify = original_notify
		assert.same({}, warns)
		assert.is_false(vim.fn.filereadable(owner_file("svc")) == 1)
	end)

	it("does not kill when the recorded forward identity is empty", function()
		local handle = vim.system({ "sleep", "30" }, { text = true })
		forward.write_owner("svc", handle.pid, registry_root)
		rewrite_record("svc", 4, "")
		local warns, original_notify = capture_notifications(vim.log.levels.WARN)
		assert.is_nil(forward.remove_forward("svc", registry_root))
		vim.notify = original_notify
		assert.truthy(warns[1]:find("identity unknown, not killed"))
		assert.is_true(process_exists(handle.pid))
		assert.is_false(vim.fn.filereadable(owner_file("svc")) == 1)
		handle:kill()
	end)

	it("round-trips starttime for a comm containing a closing bracket", function()
		local target = registry_root .. "/sleep)copy"
		vim.fn.writefile(vim.fn.readfile("/bin/sleep", "b"), target, "b")
		assert.is_true(vim.uv.fs_chmod(target, 493))
		local handle = vim.system({ target, "30" }, { text = true })
		assert.is_nil(forward.write_owner("svc-bracket", handle.pid, registry_root))
		local _, _, forward_pid, forward_start = forward.read_owner("svc-bracket", registry_root)
		assert.same(handle.pid, forward_pid)
		assert.same(expected_starttime(handle.pid), forward_start)
		handle:kill()
	end)
end)

describe("ensure_forward", function()
	local closed_port = 59999

	it("fails without pre_cmd on a closed port and releases pending", function()
		local on_ready = false
		local on_failed_count = 0
		local warns, original_notify = capture_notifications(vim.log.levels.WARN)
		forward.ensure_forward("svc-pending", { port = closed_port, probe_timeout_ms = 200 }, function()
			on_ready = true
		end, function()
			on_failed_count = on_failed_count + 1
		end)
		assert.is_true(vim.wait(5000, function()
			return on_failed_count > 0
		end))
		assert.is_false(on_ready)
		forward.ensure_forward("svc-pending", { port = closed_port, probe_timeout_ms = 200 }, function()
			on_ready = true
		end, function()
			on_failed_count = on_failed_count + 1
		end)
		assert.is_true(vim.wait(5000, function()
			return on_failed_count > 1
		end))
		vim.notify = original_notify
		assert.is_false(warn_present(warns, "already being prepared"))
	end)

	it("warns and ignores a second call while pending", function()
		local on_failed = false
		local second_failed = false
		local warns, original_notify = capture_notifications(vim.log.levels.WARN)
		forward.ensure_forward("svc-slow", { port = closed_port, probe_timeout_ms = 1500 }, function() end, function()
			on_failed = true
		end)
		forward.ensure_forward("svc-slow", { port = closed_port, probe_timeout_ms = 1500 }, function() end, function()
			second_failed = true
		end)
		assert.is_true(warn_present(warns, "already being prepared"))
		assert.is_false(second_failed)
		assert.is_true(vim.wait(5000, function()
			return on_failed
		end))
		vim.notify = original_notify
	end)

	it("refuses unsafe service names without probing", function()
		local errors = {}
		local original_notify = vim.notify
		vim.notify = function(message, level)
			if level == vim.log.levels.ERROR then
				table.insert(errors, message)
			end
		end
		local failed = false
		forward.ensure_forward("../evil", { port = closed_port, probe_timeout_ms = 200 }, function() end, function()
			failed = true
		end)
		vim.notify = original_notify
		assert.is_true(failed)
		assert.truthy(errors[1]:find("../evil", 1, true))
	end)
end)

describe("session lifecycle", function()
	before_each(function()
		real_registry_root = vim.fs.normalize(vim.fn.stdpath("cache")) .. "/sqlrun-forward"
		pid_dir = vim.fs.normalize(vim.fn.tempname()) .. ".pids"
		vim.fn.mkdir(pid_dir, "p")
	end)

	after_each(function()
		for _, service in ipairs({ "svc-live", "svc-recovery", "svc-early", "svc-exit", "svc-blocked" }) do
			pcall(vim.uv.fs_unlink, real_registry_root .. "/" .. service)
		end
		if vim.fn.filereadable(real_registry_root) == 1 then
			vim.fn.delete(real_registry_root)
		end
		vim.fn.delete(pid_dir, "rf")
	end)

	it("fills session state from a raising pre_cmd and kills it on shutdown", function()
		local port = 59871
		local pre_cmd = string.format(
			[=[python3 -c "import socket,time; s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(('127.0.0.1', %d)); s.listen(1); time.sleep(30)"]=],
			port
		)
		local ready = false
		forward.ensure_forward("svc-live", { port = port, pre_cmd = pre_cmd, probe_timeout_ms = 3000 }, function()
			ready = true
		end, function() end)
		assert.is_true(vim.wait(10000, function()
			return ready
		end))
		local _, _, forward_pid, forward_start = forward.read_owner("svc-live")
		assert.truthy(forward_pid)
		assert.truthy(forward_start ~= "")
		assert.is_true(process_exists(forward_pid))
		assert.is_true(vim.fn.filereadable(real_owner_file("svc-live")) == 1)
		forward.shutdown()
		assert.is_true(vim.wait(2000, function()
			return not process_exists(forward_pid)
		end))
		assert.is_false(vim.fn.filereadable(real_owner_file("svc-live")) == 1)
	end)

	it("does not kill live forwards with unknown identity on shutdown", function()
		local handle = vim.system({ "sleep", "30" }, { text = true })
		local warns, original_notify = capture_notifications(vim.log.levels.WARN)
		forward.shutdown({ ["svc-unknown"] = { pid = handle.pid, start = nil } })
		vim.notify = original_notify
		assert.is_true(warn_present(warns, "identity unknown or changed, not killed"))
		assert.is_true(process_exists(handle.pid))
		handle:kill()
	end)

	it("recovers a stale record with a dead owner and a live forward", function()
		local handle = vim.system({ "sleep", "30" }, { text = true })
		assert.is_nil(forward.write_owner("svc-recovery", handle.pid, real_registry_root))
		local lines = vim.fn.readfile(real_owner_file("svc-recovery"))
		lines[1] = "999998"
		lines[2] = "stale-owner-start"
		vim.fn.writefile(lines, real_owner_file("svc-recovery"))

		local on_failed = false
		local warns, original_notify = capture_notifications(vim.log.levels.WARN)
		forward.ensure_forward(
			"svc-recovery",
			{ port = 59999, pre_cmd = "sleep 30", probe_timeout_ms = 300 },
			function() end,
			function()
				on_failed = true
			end
		)
		assert.is_true(vim.wait(10000, function()
			return on_failed
		end))
		assert.is_true(vim.wait(2000, function()
			return not process_exists(handle.pid)
		end))
		assert.is_false(warn_present(warns, "already being prepared"))
		assert.is_false(vim.fn.filereadable(real_owner_file("svc-recovery")) == 1)

		local second_failed = false
		forward.ensure_forward(
			"svc-recovery",
			{ port = 59999, pre_cmd = "sleep 30", probe_timeout_ms = 300 },
			function() end,
			function()
				second_failed = true
			end
		)
		assert.is_true(vim.wait(5000, function()
			return second_failed
		end))
		vim.notify = original_notify
		assert.is_false(warn_present(warns, "already being prepared"))
	end)

	it("kills a spawn pending readiness on shutdown and suppresses late callbacks", function()
		local port = free_port()
		local pid_path = pid_dir .. "/early.pid"
		local events = { ready = 0, failed = 0 }
		forward.ensure_forward(
			"svc-early",
			{ port = port, pre_cmd = listener_pre_cmd(pid_path, port, 1.5), probe_timeout_ms = 600 },
			function()
				events.ready = events.ready + 1
			end,
			function()
				events.failed = events.failed + 1
			end
		)
		assert.is_true(vim.wait(5000, function()
			return vim.fn.filereadable(pid_path) == 1
		end))
		assert.is_true(vim.fn.filereadable(real_owner_file("svc-early")) == 1)
		local listener_pid = tonumber(vim.fn.readfile(pid_path)[1])
		forward.shutdown()
		assert.is_true(vim.wait(2000, function()
			return not process_exists(listener_pid)
		end))
		assert.is_false(vim.fn.filereadable(real_owner_file("svc-early")) == 1)
		assert.is_false(vim.wait(3500, function()
			return events.ready > 0 or events.failed > 0
		end))
		assert.same({ ready = 0, failed = 0 }, events)
		assert.is_false(vim.fn.filereadable(real_owner_file("svc-early")) == 1)
		local warns, original_notify = capture_notifications(vim.log.levels.WARN)
		forward.shutdown()
		vim.notify = original_notify
		assert.same({}, warns)
	end)

	it("leaves nothing behind when the spawned pre_cmd exits before the port comes up", function()
		local port = free_port()
		local failed_count = 0
		forward.ensure_forward(
			"svc-exit",
			{ port = port, pre_cmd = "true", probe_timeout_ms = 500 },
			function() end,
			function()
				failed_count = failed_count + 1
			end
		)
		assert.is_true(vim.wait(5000, function()
			return failed_count > 0
		end))
		assert.is_false(vim.fn.filereadable(real_owner_file("svc-exit")) == 1)
		assert.is_false(vim.fn.filereadable(real_owner_file("svc-exit") .. "." .. vim.uv.getpid() .. ".tmp") == 1)
		local warns, original_notify = capture_notifications(vim.log.levels.WARN)
		forward.shutdown()
		vim.notify = original_notify
		assert.same({}, warns)
	end)

	it("surfaces a record write failure and cleans up the spawned process", function()
		vim.fn.mkdir(real_owner_file("svc-blocked"), "p")
		local port = free_port()
		local errors = {}
		local original_notify = vim.notify
		vim.notify = function(message, level)
			if level == vim.log.levels.ERROR then
				table.insert(errors, message)
			end
		end
		local failed_count = 0
		forward.ensure_forward(
			"svc-blocked",
			{ port = port, pre_cmd = "sleep 30", probe_timeout_ms = 800 },
			function() end,
			function()
				failed_count = failed_count + 1
			end
		)
		assert.is_true(vim.wait(5000, function()
			return failed_count > 0
		end))
		vim.notify = original_notify
		assert.truthy(warn_present(errors, "cannot move"))
		assert.is_false(vim.fn.filereadable(real_owner_file("svc-blocked") .. "." .. vim.uv.getpid() .. ".tmp") == 1)
		assert.is_true(vim.wait(2000, function()
			return any_process_with_cmdline("sleep 30 ") == nil
		end))
	end)
end)
