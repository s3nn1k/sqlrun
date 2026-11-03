local M = {}

local probe_interval_ms = 100
local session_forwards = {}

local function notify_error(message)
	vim.notify("sqlrun: " .. message, vim.log.levels.ERROR)
end

local function cache_root()
	return vim.fs.normalize(vim.fn.stdpath("cache")) .. "/sqlrun-forward"
end

local function owner_path(service)
	return cache_root() .. "/" .. service
end

local function process_start(pid)
	local result = vim.system({ "ps", "-o", "lstart=", "-p", tostring(pid) }, { text = true }):wait()
	if result.code ~= 0 then
		return nil
	end
	return vim.trim(result.stdout or "")
end

local function read_owner(service)
	local file = io.open(owner_path(service), "r")
	if not file then
		return nil
	end
	local owner_pid = tonumber(file:read("*l"))
	local owner_start = vim.trim(file:read("*l") or "")
	local forward_pid = tonumber(file:read("*l"))
	file:close()
	return owner_pid, owner_start, forward_pid
end

local function owner_alive(service)
	local owner_pid, owner_start = read_owner(service)
	if not owner_pid then
		return false
	end
	local signal, err = vim.uv.kill(owner_pid, 0)
	if not signal and not tostring(err):find("EPERM") then
		return false
	end
	if owner_start ~= "" and process_start(owner_pid) ~= owner_start then
		return false
	end
	return true
end

local function write_owner(service, forward_pid)
	local root = cache_root()
	local ok = pcall(vim.fn.mkdir, root, "p")
	if not ok then
		return "cannot create " .. root
	end
	local file = io.open(owner_path(service), "w")
	if not file then
		return "cannot write " .. owner_path(service)
	end
	local owner_pid = vim.uv.getpid()
	file:write(tostring(owner_pid) .. "\n" .. (process_start(owner_pid) or "") .. "\n" .. tostring(forward_pid) .. "\n")
	file:close()
	return nil
end

local function remove_forward(service)
	local _, _, forward_pid = read_owner(service)
	if not forward_pid then
		pcall(vim.uv.fs_unlink, owner_path(service))
		return nil
	end
	local ok, err = pcall(vim.uv.kill, forward_pid)
	pcall(vim.uv.fs_unlink, owner_path(service))
	if not ok then
		return "cannot kill forward " .. tostring(forward_pid) .. " of " .. service .. ": " .. tostring(err)
	end
	return nil
end

local function tcp_probe(port, timeout_ms, on_result)
	local deadline = vim.uv.now() + timeout_ms
	local function attempt()
		local handle = vim.uv.new_tcp()
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

function M.ensure_forward(service, opts, on_ready)
	if not opts.port then
		notify_error("service " .. service .. ": no valid port in connections.toml")
		return
	end
	tcp_probe(opts.port, opts.probe_timeout_ms, function(alive)
		if alive then
			on_ready()
			return
		end
		if not (opts.pre_cmd and opts.pre_cmd ~= "") then
			notify_error("service " .. service .. ": port " .. opts.port .. " is down and pre_cmd is not set")
			return
		end
		local handle = vim.system({ "sh", "-c", "exec " .. opts.pre_cmd }, { detach = true })
		tcp_probe(opts.port, opts.probe_timeout_ms, function(came_up)
			if not came_up then
				pcall(vim.uv.kill, handle.pid)
				notify_error(
					"service " .. service .. ": port-forward did not come up within " .. opts.probe_timeout_ms .. " ms"
				)
				return
			end
			local write_error = write_owner(service, handle.pid)
			if write_error then
				pcall(vim.uv.kill, handle.pid)
				notify_error(write_error)
				return
			end
			session_forwards[service] = handle.pid
			on_ready()
		end)
	end)
end

function M.sweep()
	local root = cache_root()
	if vim.fn.isdirectory(root) ~= 1 then
		return
	end
	for service in vim.fs.dir(root) do
		if not owner_alive(service) then
			local err = remove_forward(service)
			if err then
				notify_error(err)
			end
		end
	end
end

function M.shutdown()
	for service, forward_pid in pairs(session_forwards) do
		pcall(vim.uv.kill, forward_pid)
		pcall(vim.uv.fs_unlink, owner_path(service))
	end
	session_forwards = {}
end

return M
