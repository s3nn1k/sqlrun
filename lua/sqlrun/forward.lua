local ini = require("sqlrun.ini")

local M = {}

local probe_interval_ms = 100
local registry_path_suffix = "/sqlrun-forward"
local pending = {}
local pending_probes = {}
local session_forwards = {}
local shutdown_epoch = 0

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
	local fields = vim.split(after_comm, "%s+", { trimempty = true })
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
	local owner_pid_line = file:read("*l")
	local owner_start_line = file:read("*l")
	local forward_pid_line = file:read("*l")
	local forward_start_line = file:read("*l")
	file:close()
	if owner_pid_line == nil or owner_start_line == nil or forward_pid_line == nil or forward_start_line == nil then
		return nil
	end
	return tonumber(owner_pid_line), owner_start_line, tonumber(forward_pid_line), forward_start_line
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

local function kill_pid(pid)
	local killed, kill_err = vim.uv.kill(pid)
	if killed or tostring(kill_err):find("ESRCH") then
		return true
	end
	return nil, kill_err
end

local function stop_owned_process(owned_forward)
	if owned_forward.handle then
		local ok, kill_err = pcall(owned_forward.handle.kill, owned_forward.handle)
		if ok then
			return true
		end
		return nil, kill_err
	end
	return kill_pid(owned_forward.pid)
end

local function cleanup_forward(service, owned_forward)
	local current_start = process_identity(owned_forward.pid)
	if
		current_start ~= nil
		and owned_forward.start ~= nil
		and owned_forward.start ~= ""
		and current_start == owned_forward.start
	then
		local stopped, kill_err = stop_owned_process(owned_forward)
		if not stopped and not tostring(kill_err):find("ESRCH") then
			notify_error(
				"cannot kill forward " .. tostring(owned_forward.pid) .. " of " .. service .. ": " .. tostring(kill_err)
			)
		end
	elseif current_start ~= nil then
		notify_warn(
			"forward pid " .. owned_forward.pid .. " of " .. service .. " identity unknown or changed, not killed"
		)
	end
	local _, _, record_pid = M.read_owner(service)
	if record_pid == owned_forward.pid then
		pcall(vim.uv.fs_unlink, owner_path(service))
	end
end

local function cleanup_owned(service)
	local owned_forward = session_forwards[service]
	if not owned_forward then
		return
	end
	session_forwards[service] = nil
	cleanup_forward(service, owned_forward)
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
	local wrote, write_result, write_err = pcall(file.write, file, record, "\n")
	if not wrote or (write_result == nil and write_err ~= nil) then
		local message = not wrote and write_result or write_err
		pcall(file.close, file)
		pcall(vim.uv.fs_unlink, tmp_path)
		return "cannot write " .. tmp_path .. ": " .. tostring(message)
	end
	local closed, close_result, close_err = pcall(file.close, file)
	if not closed or (close_result == nil and close_err ~= nil) then
		local message = not closed and close_result or close_err
		pcall(vim.uv.fs_unlink, tmp_path)
		return "cannot write " .. tmp_path .. ": " .. tostring(message)
	end
	local renamed, rename_err = vim.uv.fs_rename(tmp_path, path)
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
	local killed, kill_err = kill_pid(forward_pid)
	pcall(vim.uv.fs_unlink, owner_path(service, root))
	if not killed then
		notify_error("cannot kill forward " .. tostring(forward_pid) .. " of " .. service .. ": " .. tostring(kill_err))
	end
end

local function tcp_probe(port, timeout_ms, on_result)
	local deadline = vim.uv.now() + timeout_ms
	local socket
	local timer
	local done = false
	local function attempt()
		socket = vim.uv.new_tcp()
		if not socket then
			vim.schedule(function()
				if not done then
					on_result(false)
				end
			end)
			return
		end
		socket:connect("127.0.0.1", port, function(err)
			if socket and not socket:is_closing() then
				socket:close()
			end
			socket = nil
			if done then
				return
			end
			if not err or vim.uv.now() >= deadline then
				vim.schedule(function()
					if not done then
						on_result(not err)
					end
				end)
				return
			end
			timer = vim.uv.new_timer()
			timer:start(probe_interval_ms, 0, function()
				timer:stop()
				timer:close()
				timer = nil
				attempt()
			end)
		end)
	end
	attempt()
	return function()
		done = true
		if socket and not socket:is_closing() then
			socket:close()
		end
		if timer and not timer:is_closing() then
			timer:stop()
			timer:close()
		end
	end
end

function M.ensure_forward(service, opts, on_ready, on_failed)
	if not ini.valid_service_name(service) then
		notify_error("unsafe service name: " .. service)
		on_failed()
		return
	end
	if not opts.port then
		notify_error("service " .. service .. ": no valid port in connections.toml")
		on_failed()
		return
	end
	if pending[service] then
		notify_warn("query for " .. service .. " is already being prepared")
		return
	end
	pending[service] = true
	local startup_generation = shutdown_epoch

	local function cancelled()
		return startup_generation ~= shutdown_epoch
	end

	local function release_pending()
		pending[service] = nil
		pending_probes[service] = nil
	end

	local function ready()
		if cancelled() then
			return
		end
		release_pending()
		on_ready()
	end

	local function fail(message)
		if cancelled() then
			return
		end
		release_pending()
		notify_error(message)
		on_failed()
	end

	local function start_probe(on_result)
		pending_probes[service] = tcp_probe(opts.port, opts.probe_timeout_ms, on_result)
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
		session_forwards[service] = { pid = handle.pid, start = process_identity(handle.pid), handle = handle }
		local write_error = M.write_owner(service, handle.pid)
		if write_error then
			cleanup_owned(service)
			fail(write_error)
			return
		end
		start_probe(function(came_up)
			if cancelled() then
				return
			end
			if not came_up then
				cleanup_owned(service)
				fail(
					"service " .. service .. ": port-forward did not come up within " .. opts.probe_timeout_ms .. " ms"
				)
				return
			end
			ready()
		end)
	end

	local ok, setup_err = pcall(function()
		start_probe(function(alive)
			if cancelled() then
				return
			end
			if alive then
				if not M.owner_alive(service) then
					notify_warn("port " .. opts.port .. " is up but not owned by sqlrun")
				end
				ready()
				return
			end
			if forward_alive(service) then
				start_probe(function(came_up)
					if cancelled() then
						return
					end
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
		fail("forward check failed: " .. tostring(setup_err))
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
	shutdown_epoch = shutdown_epoch + 1
	for _, cancel in pairs(pending_probes) do
		cancel()
	end
	pending_probes = {}
	pending = {}
	local forwards = session or session_forwards
	for service, owned_forward in pairs(forwards) do
		cleanup_forward(service, owned_forward)
	end
	session_forwards = {}
end

return M
