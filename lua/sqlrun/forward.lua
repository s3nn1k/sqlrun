local ini = require("sqlrun.ini")

local M = {}

local probe_interval_ms = 100
local registry_path_suffix = "/sqlrun-forward"
local pending = {}
local session_forwards = {}

local function notify_error(message)
	vim.notify("sqlrun: " .. message, vim.log.levels.ERROR)
end

local function notify_warn(message)
	vim.notify("sqlrun: " .. message, vim.log.levels.WARN)
end

local function cache_root(root)
	return root or vim.fs.normalize(vim.fn.stdpath("cache")) .. registry_path_suffix
end

local function owner_path(service, root)
	return cache_root(root) .. "/" .. service
end

local function process_starttime(pid)
	local stat = io.open("/proc/" .. tostring(pid) .. "/stat", "r")
	if not stat then
		return nil
	end
	local content = stat:read("*a")
	stat:close()
	local after_comm = content:match(".*%)%s*(.*)$")
	if not after_comm then
		return nil
	end
	local fields = {}
	for field in after_comm:gmatch("%S+") do
		table.insert(fields, field)
	end
	local comm_last_field = 2
	local starttime_field = 22
	return fields[starttime_field - comm_last_field]
end

local function process_identity(pid)
	local starttime = process_starttime(pid)
	if starttime then
		return starttime
	end
	local result = vim.system({ "env", "TZ=UTC", "ps", "-o", "lstart=", "-p", tostring(pid) }, { text = true }):wait()
	if result.code ~= 0 then
		return nil
	end
	return vim.trim(result.stdout or "")
end

function M.read_owner(service, root)
	local file = io.open(owner_path(service, root), "r")
	if not file then
		return nil
	end
	local owner_pid = tonumber(file:read("*l"))
	local owner_start = vim.trim(file:read("*l") or "")
	local forward_pid = tonumber(file:read("*l"))
	local forward_start = vim.trim(file:read("*l") or "")
	file:close()
	return owner_pid, owner_start, forward_pid, forward_start
end

function M.owner_alive(service, root)
	local owner_pid, owner_start = M.read_owner(service, root)
	if not owner_pid then
		return false
	end
	local signal, err = vim.uv.kill(owner_pid, 0)
	if not signal and not tostring(err):find("EPERM") then
		return false
	end
	if owner_start ~= "" and process_identity(owner_pid) ~= owner_start then
		return false
	end
	return true
end

local function forward_alive(service, root)
	local _, _, forward_pid, forward_start = M.read_owner(service, root)
	if not forward_pid then
		return false
	end
	local current_start = process_identity(forward_pid)
	if not current_start then
		return false
	end
	if forward_start ~= "" and current_start ~= forward_start then
		return false
	end
	return true
end

function M.write_owner(service, forward_pid, root)
	local target_root = cache_root(root)
	if not pcall(vim.fn.mkdir, target_root, "p") then
		return "cannot create " .. target_root
	end
	local path = owner_path(service, root)
	local tmp_path = path .. "." .. vim.uv.getpid() .. ".tmp"
	local file = io.open(tmp_path, "w")
	if not file then
		return "cannot write " .. tmp_path
	end
	local owner_pid = vim.uv.getpid()
	local record = table.concat({
		tostring(owner_pid),
		process_identity(owner_pid) or "",
		tostring(forward_pid),
		process_identity(forward_pid) or "",
	}, "\n")
	local write_ok, write_err = pcall(file.write, file, record, "\n")
	local close_ok, close_err = pcall(file.close, file)
	if not write_ok or not close_ok then
		pcall(vim.uv.fs_unlink, tmp_path)
		return "cannot write " .. tmp_path .. ": " .. tostring(write_err or close_err)
	end
	local renamed, rename_err = pcall(vim.uv.fs_rename, tmp_path, path)
	if not renamed then
		pcall(vim.uv.fs_unlink, tmp_path)
		return "cannot move " .. tmp_path .. " to " .. path .. ": " .. tostring(rename_err)
	end
	return nil
end

function M.remove_forward(service, root)
	local _, _, forward_pid, forward_start = M.read_owner(service, root)
	if not forward_pid then
		pcall(vim.uv.fs_unlink, owner_path(service, root))
		return
	end
	local current_start = process_identity(forward_pid)
	if not current_start then
		pcall(vim.uv.fs_unlink, owner_path(service, root))
		return
	end
	if forward_start == nil or forward_start == "" then
		pcall(vim.uv.fs_unlink, owner_path(service, root))
		notify_warn("forward pid " .. forward_pid .. " of " .. service .. " identity unknown, not killed")
		return
	end
	if current_start ~= forward_start then
		pcall(vim.uv.fs_unlink, owner_path(service, root))
		notify_warn("forward pid " .. forward_pid .. " of " .. service .. " changed identity, not killed")
		return
	end
	local ok, err = pcall(vim.uv.kill, forward_pid)
	pcall(vim.uv.fs_unlink, owner_path(service, root))
	if not ok then
		notify_error("cannot kill forward " .. tostring(forward_pid) .. " of " .. service .. ": " .. tostring(err))
	end
end

local function tcp_probe(port, timeout_ms, on_result)
	local deadline = vim.uv.now() + timeout_ms
	local function attempt()
		local handle = vim.uv.new_tcp()
		if not handle then
			vim.schedule(function()
				on_result(false)
			end)
			return
		end
		handle:connect("127.0.0.1", port, function(err)
			handle:close()
			if not err or vim.uv.now() >= deadline then
				vim.schedule(function()
					on_result(not err)
				end)
				return
			end
			local timer = vim.uv.new_timer()
			timer:start(probe_interval_ms, 0, function()
				timer:stop()
				timer:close()
				attempt()
			end)
		end)
	end
	attempt()
end

function M.ensure_forward(service, opts, on_ready, on_failed)
	if not ini.valid_service_name(service) then
		notify_error("unsafe service name: " .. service)
		if on_failed then
			on_failed()
		end
		return
	end
	if not opts.port then
		notify_error("service " .. service .. ": no valid port in connections.toml")
		if on_failed then
			on_failed()
		end
		return
	end
	if pending[service] then
		notify_warn("query for " .. service .. " is already being prepared")
		return
	end
	pending[service] = true

	local function release_pending()
		pending[service] = nil
	end

	local function ready()
		release_pending()
		on_ready()
	end

	local function fail(message)
		release_pending()
		notify_error(message)
		if on_failed then
			on_failed()
		end
	end

	local function spawn_forward()
		pcall(vim.uv.fs_unlink, owner_path(service))
		if not (opts.pre_cmd and opts.pre_cmd ~= "") then
			fail("service " .. service .. ": port " .. opts.port .. " is down and pre_cmd is not set")
			return
		end
		local spawned, handle_or_err = pcall(vim.system, { "sh", "-c", "exec " .. opts.pre_cmd }, { detach = true })
		if not spawned then
			fail("service " .. service .. ": cannot spawn pre_cmd: " .. tostring(handle_or_err))
			return
		end
		local handle = handle_or_err
		tcp_probe(opts.port, opts.probe_timeout_ms, function(came_up)
			if not came_up then
				pcall(vim.uv.kill, handle.pid)
				fail(
					"service " .. service .. ": port-forward did not come up within " .. opts.probe_timeout_ms .. " ms"
				)
				return
			end
			local write_error = M.write_owner(service, handle.pid)
			if write_error then
				pcall(vim.uv.kill, handle.pid)
				fail(write_error)
				return
			end
			session_forwards[service] = { pid = handle.pid, start = process_identity(handle.pid) }
			ready()
		end)
	end

	local ok, setup_err = pcall(function()
		tcp_probe(opts.port, opts.probe_timeout_ms, function(alive)
			if alive then
				if not M.owner_alive(service) then
					notify_warn("port " .. opts.port .. " is up but not owned by sqlrun")
				end
				ready()
				return
			end
			if forward_alive(service) then
				tcp_probe(opts.port, opts.probe_timeout_ms, function(came_up)
					if came_up then
						ready()
						return
					end
					if M.owner_alive(service) then
						fail(
							"service "
								.. service
								.. ": live forward did not bring port "
								.. opts.port
								.. " up within "
								.. opts.probe_timeout_ms
								.. " ms"
						)
						return
					end
					M.remove_forward(service)
					spawn_forward()
				end)
				return
			end
			spawn_forward()
		end)
	end)
	if not ok then
		release_pending()
		notify_error("forward check failed: " .. tostring(setup_err))
		if on_failed then
			on_failed()
		end
	end
end

function M.sweep()
	local root = cache_root()
	if vim.fn.isdirectory(root) ~= 1 then
		return
	end
	for service in vim.fs.dir(root) do
		if not M.owner_alive(service) then
			M.remove_forward(service)
		end
	end
end

function M.shutdown(session)
	local forwards = session or session_forwards
	for service, forward in pairs(forwards) do
		local current_start = process_identity(forward.pid)
		if current_start ~= nil and forward.start ~= nil and forward.start ~= "" and current_start == forward.start then
			pcall(vim.uv.kill, forward.pid)
		elseif current_start ~= nil then
			notify_warn(
				"forward pid " .. forward.pid .. " of " .. service .. " identity unknown or changed, not killed"
			)
		end
		pcall(vim.uv.fs_unlink, owner_path(service))
	end
	session_forwards = {}
end

return M
