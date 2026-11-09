local forward = require("sqlrun.forward")
local ini = require("sqlrun.ini")
local result = require("sqlrun.result")

local M = {}

local defaults = {
	pg_service_path = os.getenv("PGSERVICEFILE") or "~/.pg_service.conf",
	connections_path = "~/credentials/postgres/connections.toml",
	max_lines = 2000,
	probe_timeout_ms = 15000,
}

local config = vim.deepcopy(defaults)
local running = false

local known_setup_keys = {
	pg_service_path = "string",
	connections_path = "string",
	max_lines = "number",
	probe_timeout_ms = "number",
}

local function notify_error(message)
	vim.notify("sqlrun: " .. message, vim.log.levels.ERROR)
end

local function fail_with_error(message)
	running = false
	vim.g.sqlrun_last_status = "error"
	vim.api.nvim_exec_autocmds("User", { pattern = "SqlrunRunDone", modeline = false })
	notify_error(message)
end

local function expand_path(path)
	return vim.fs.normalize(vim.fn.expand(path))
end

function M.setup(opts)
	for key, value in pairs(opts or {}) do
		local expected_type = known_setup_keys[key]
		if expected_type then
			vim.validate(key, value, expected_type)
		else
			vim.notify_once("sqlrun: unknown setup key: " .. tostring(key), vim.log.levels.WARN)
		end
	end
	config = vim.tbl_deep_extend("force", defaults, opts or {})
end

local function service_names(connections, pg_service)
	local names = vim.tbl_keys(vim.tbl_extend("force", connections or {}, pg_service or {}))
	table.sort(names)
	return names
end

local function open_picker(names, handler)
	local ok, pickers = pcall(require, "telescope.pickers")
	if not ok then
		notify_error("service picker needs telescope.nvim: " .. tostring(pickers))
		handler(nil)
		return
	end
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")
	local finders = require("telescope.finders")
	local conf = require("telescope.config").values

	local finished = false
	local function finish(service)
		if finished then
			return
		end
		finished = true
		handler(service)
	end

	pickers
		.new({}, {
			prompt_title = "SQL service",
			finder = finders.new_table({ results = names }),
			sorter = conf.generic_sorter({}),
			attach_mappings = function(prompt_bufnr, map)
				local function cancel()
					actions.close(prompt_bufnr)
					finish(nil)
					return true
				end
				for _, key in ipairs({ "<C-c>", "<esc>" }) do
					map("i", key, cancel)
					map("n", key, cancel)
				end
				map("n", "q", cancel)
				actions.select_default:replace(function()
					local entry = action_state.get_selected_entry()
					finish(entry and entry.value or nil)
					actions.close(prompt_bufnr)
				end)
				vim.api.nvim_create_autocmd("BufWipeout", {
					buffer = prompt_bufnr,
					callback = function()
						finish(nil)
					end,
				})
				return true
			end,
		})
		:find()
end

function M.pick_service(on_selected)
	local handler = on_selected or function() end
	local connections = ini.read_connections(config.connections_path)
	local pg_service = ini.read_pg_service(config.pg_service_path)
	if connections and next(connections) then
		local consistency_error = ini.validate_consistency(connections, pg_service)
		if consistency_error then
			notify_error(consistency_error)
			handler(nil)
			return
		end
	end
	local names = service_names(connections, pg_service)
	if #names == 0 then
		vim.notify("sqlrun: no pg services found", vim.log.levels.WARN)
		handler(nil)
		return
	end
	open_picker(names, handler)
end

local function visual_type()
	local mode = vim.fn.mode()
	if mode:find("^[VS]") then
		return "V"
	end
	if mode:find("^[\22\19]") then
		return "\22"
	end
	return "v"
end

local function visual_selection()
	local lines = vim.fn.getregion(vim.fn.getpos("v"), vim.fn.getpos("."), { type = visual_type() })
	if not lines or #lines == 0 then
		return nil
	end
	return vim.trim(table.concat(lines, "\n"))
end

local function current_target()
	local mode = vim.fn.mode()
	if mode:find("^[vV\22sS\19]") then
		local text = visual_selection()
		if not text or text == "" then
			vim.notify("sqlrun: empty visual selection", vim.log.levels.WARN)
			return nil
		end
		return { text = text, source = "(selection)" }
	end
	local path = expand_path(vim.api.nvim_buf_get_name(0))
	if path == "" or vim.fn.filereadable(path) ~= 1 then
		vim.notify("sqlrun: current buffer is not a file, select a query in visual mode", vim.log.levels.WARN)
		return nil
	end
	if vim.bo.modified then
		local saved, save_err = pcall(vim.cmd.update)
		if not saved then
			notify_error("cannot save buffer: " .. tostring(save_err))
			return nil
		end
	end
	return { path = path, source = path }
end

local function psql_args(service, target, columns)
	local args = {
		"psql",
		"-X",
		"-w",
		"-v",
		"ON_ERROR_STOP=1",
		"-P",
		"pager=off",
		"-P",
		"columns=" .. tostring(columns),
		"service=" .. service,
	}
	if target.path then
		vim.list_extend(args, { "-f", target.path })
	else
		vim.list_extend(args, { "-c", target.text })
	end
	return args
end

local function execute(service, target)
	local win = result.open()
	local columns = vim.api.nvim_win_get_width(win)
	result.show_running(service, target.source)
	local started_at = vim.uv.hrtime()
	local ok, spawn_or_err = pcall(
		vim.system,
		psql_args(service, target, columns),
		{ text = true, env = { PGSERVICEFILE = expand_path(config.pg_service_path) } },
		function(done)
			running = false
			vim.schedule(function()
				result.show({
					service = service,
					source = target.source,
					elapsed_seconds = (vim.uv.hrtime() - started_at) / 1e9,
					code = done.code,
					stdout = done.stdout,
					stderr = done.stderr,
					max_lines = config.max_lines,
				})
				vim.g.sqlrun_last_status = done.code == 0 and "ok" or "error"
				vim.api.nvim_exec_autocmds("User", { pattern = "SqlrunRunDone", modeline = false })
			end)
		end
	)
	if not ok then
		fail_with_error("cannot run psql: " .. tostring(spawn_or_err))
	end
end

local function start_query(service, target)
	vim.api.nvim_exec_autocmds("User", { pattern = "SqlrunRunStart", modeline = false })
	local connections = ini.read_connections(config.connections_path)
	if connections and connections[service] then
		local pg_service = ini.read_pg_service(config.pg_service_path)
		local consistency_error = ini.validate_consistency(connections, pg_service)
		if consistency_error then
			fail_with_error(consistency_error)
			return
		end
		local section = connections[service]
		local ensured, ensure_err = pcall(forward.ensure_forward, service, {
			port = ini.parse_port(section),
			pre_cmd = section.pre_cmd,
			probe_timeout_ms = config.probe_timeout_ms,
		}, function()
			execute(service, target)
		end, function()
			running = false
		end)
		if not ensured then
			fail_with_error("forward check failed: " .. tostring(ensure_err))
		end
		return
	end
	local pg_service = ini.read_pg_service(config.pg_service_path)
	if not pg_service or not pg_service[service] then
		fail_with_error("service " .. service .. " not found in pg_service or connections")
		return
	end
	execute(service, target)
end

function M.run()
	if running then
		vim.notify("sqlrun: query already running", vim.log.levels.WARN)
		return
	end
	running = true
	local ok, target_or_err = pcall(current_target)
	if not ok then
		running = false
		notify_error("cannot capture the query: " .. tostring(target_or_err))
		return
	end
	if not target_or_err then
		running = false
		return
	end
	M.pick_service(function(chosen)
		if not chosen then
			running = false
			return
		end
		start_query(chosen, target_or_err)
	end)
end

function M.sweep()
	forward.sweep()
end

function M.shutdown()
	forward.shutdown()
end

return M
