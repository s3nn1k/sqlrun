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
end)
