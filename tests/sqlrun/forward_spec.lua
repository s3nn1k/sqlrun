local forward = require("sqlrun.forward")

local registry_root

local function owner_file(service)
	return registry_root .. "/" .. service
end

local function process_exists(pid)
	local stat = io.open("/proc/" .. tostring(pid) .. "/stat", "r")
	if not stat then
		return false
	end
	stat:close()
	return true
end

local function rewrite_record(service, line_index, value)
	local lines = vim.fn.readfile(owner_file(service))
	lines[line_index] = value
	vim.fn.writefile(lines, owner_file(service))
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
end)

describe("ensure_forward", function()
	local closed_port = 59999

	local function capture_warns()
		local warns = {}
		local original_notify = vim.notify
		vim.notify = function(message, level)
			if level == vim.log.levels.WARN then
				table.insert(warns, message)
			end
		end
		return warns, original_notify
	end

	local function warn_present(warns, needle)
		for _, message in ipairs(warns) do
			if message:find(needle, 1, true) then
				return true
			end
		end
		return false
	end

	it("fails without pre_cmd on a closed port and releases pending", function()
		local on_ready = false
		local on_failed_count = 0
		local warns, original_notify = capture_warns()
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
		local warns, original_notify = capture_warns()
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
