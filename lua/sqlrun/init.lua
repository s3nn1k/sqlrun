local forward = require("sqlrun.forward")
local ini = require("sqlrun.ini")
local result = require("sqlrun.result")

local M = {}

local defaults = {
	pg_service_path = os.getenv("PGSERVICEFILE") or "~/.pg_service.conf",
	connections_path = "~/credentials/postgres/connections.toml",
	max_lines = 2000,
	probe_timeout_ms = 15000,
	border = "single",
}

local config = vim.deepcopy(defaults)
local running = false

local function notify_error(message)
	vim.notify("sqlrun: " .. message, vim.log.levels.ERROR)
end

local function expand_path(path)
	return vim.fs.normalize(vim.fn.expand(path))
end

function M.setup(opts)
	config = vim.tbl_deep_extend("force", defaults, opts or {})
end

function M.cached_service()
	return vim.b.sqlrun_service or vim.g.sqlrun_service
end

local function store_service(service)
	vim.b.sqlrun_service = service
	vim.g.sqlrun_service = service
end

local function service_names(connections, pg_service)
	local seen = {}
	for name in pairs(connections or {}) do
		seen[name] = true
	end
	for name in pairs(pg_service or {}) do
		seen[name] = true
	end
	local names = vim.tbl_keys(seen)
	table.sort(names)
	return names
end

local function open_picker(names, on_selected)
	local ok, pickers = pcall(require, "telescope.pickers")
	if not ok then
		notify_error("service picker needs telescope.nvim: " .. tostring(pickers))
		return
	end
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")
	local finders = require("telescope.finders")
	local conf = require("telescope.config").values
	pickers
		.new({}, {
			prompt_title = "SQL service",
			finder = finders.new_table({ results = names }),
			sorter = conf.generic_sorter({}),
			attach_mappings = function(prompt_bufnr)
				actions.select_default:replace(function()
					local entry = action_state.get_selected_entry()
					actions.close(prompt_bufnr)
					if entry then
						store_service(entry.value)
						on_selected(entry.value)
					end
				end)
				return true
			end,
		})
		:find()
end

function M.pick_service(on_selected)
	local connections = ini.read_connections(config.connections_path)
	local pg_service = ini.read_pg_service(config.pg_service_path)
	if connections and next(connections) then
		local consistency_error = ini.validate_consistency(connections, pg_service)
		if consistency_error then
			notify_error(consistency_error)
			return
		end
	end
	local names = service_names(connections, pg_service)
	if #names == 0 then
		vim.notify("sqlrun: no pg services found", vim.log.levels.WARN)
		return
	end
	open_picker(names, on_selected or store_service)
end

local function visual_selection()
	local start = vim.fn.getpos("'<")
	local finish = vim.fn.getpos("'>")
	local lines = vim.api.nvim_buf_get_lines(0, start[2] - 1, finish[2], false)
	if #lines == 0 then
		return nil
	end
	return vim.trim(table.concat(lines, "\n"))
end

local function current_target()
	local mode = vim.fn.mode()
	if mode:find("^[vV\22]") then
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
	if not win then
		return
	end
	local columns = vim.api.nvim_win_get_width(win)
	result.show_running(service, target.source)
	running = true
	local started_at = vim.uv.hrtime()
	vim.system(psql_args(service, target, columns), { text = true }, function(done)
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
		end)
	end)
end

local function start_query(service, target)
	local connections = ini.read_connections(config.connections_path)
	if connections and connections[service] then
		local consistency_error = ini.validate_consistency(connections, ini.read_pg_service(config.pg_service_path))
		if consistency_error then
			notify_error(consistency_error)
			return
		end
		local section = connections[service]
		forward.ensure_forward(
			service,
			{ port = ini.parse_port(section), pre_cmd = section.pre_cmd, probe_timeout_ms = config.probe_timeout_ms },
			function()
				execute(service, target)
			end
		)
		return
	end
	local pg_service = ini.read_pg_service(config.pg_service_path)
	if not pg_service or not pg_service[service] then
		notify_error("service " .. service .. " not found in pg_service or connections")
		return
	end
	execute(service, target)
end

function M.run()
	if running then
		vim.notify("sqlrun: query already running", vim.log.levels.WARN)
		return
	end
	local target = current_target()
	if not target then
		return
	end
	local service = M.cached_service()
	if service then
		start_query(service, target)
	else
		M.pick_service(function(chosen)
			start_query(chosen, target)
		end)
	end
end

function M.sweep()
	forward.sweep()
end

function M.shutdown()
	forward.shutdown()
end

return M
