local M = {}

local utf8_bom = "\239\187\191"
local service_name_pattern = "^[%w_.-]+$"

local function strip_quotes(value)
	if #value >= 2 and value:sub(1, 1) == '"' and value:sub(-1) == '"' then
		return value:sub(2, -2)
	end
	return value
end

function M.parse_ini(text)
	text = text:gsub("^" .. utf8_bom, "")
	local sections = {}
	local current = nil
	for line in text:gmatch("[^\r\n]+") do
		local trimmed = vim.trim(line)
		if trimmed ~= "" and trimmed:sub(1, 1) ~= "#" and trimmed:sub(1, 1) ~= ";" then
			local section = trimmed:match("^%[(.+)%]$")
			if section then
				current = vim.trim(section)
				sections[current] = sections[current] or {}
			elseif current then
				local key, value = trimmed:match("^([^=]+)=(.*)$")
				if key then
					sections[current][vim.trim(key)] = strip_quotes(vim.trim(value))
				end
			end
		end
	end
	return sections
end

function M.parse_port(section)
	if type(section) ~= "table" then
		return nil
	end
	local port = tonumber(section.port)
	if not port or port < 1 or port > 65535 or port % 1 ~= 0 then
		return nil
	end
	return port
end

function M.valid_service_name(name)
	return type(name) == "string" and name:match(service_name_pattern) ~= nil
end

local function expand(path)
	return vim.fs.normalize(vim.fn.expand(path))
end

local warned_sources = {}

local function sanitize_sections(sections, path, source)
	local valid = {}
	local unsafe = {}
	for name, section in pairs(sections) do
		if M.valid_service_name(name) then
			valid[name] = section
		else
			table.insert(unsafe, name)
		end
	end
	if #unsafe > 0 and not warned_sources[path] then
		warned_sources[path] = true
		table.sort(unsafe)
		local listed = vim.tbl_map(function(name)
			return '"' .. name .. '"'
		end, unsafe)
		vim.notify(
			"sqlrun: skipping services with unsafe names in " .. source .. ": " .. table.concat(listed, ", "),
			vim.log.levels.WARN
		)
	end
	return valid
end

local function read_sections(path, source)
	local file = io.open(path, "r")
	if not file then
		return nil
	end
	local text = file:read("*a")
	file:close()
	return sanitize_sections(M.parse_ini(text), path, source)
end

function M.read_pg_service(path)
	return read_sections(expand(path or os.getenv("PGSERVICEFILE") or "~/.pg_service.conf"), "pg_service")
end

function M.read_connections(path)
	return read_sections(expand(path or "~/credentials/postgres/connections.toml"), "connections.toml")
end

function M.validate_consistency(connections, pg_service)
	if not connections or not pg_service then
		return "cannot read connections.toml or pg_service file"
	end
	for service, section in pairs(connections) do
		local pg_section = pg_service[service]
		if not pg_section then
			return string.format('service "%s": no [%s] section in pg_service', service, service)
		end
		local connections_port = M.parse_port(section)
		local pg_port = M.parse_port(pg_section)
		if not connections_port or not pg_port then
			return string.format(
				'service "%s": invalid port (connections: %s / pg_service: %s)',
				service,
				tostring(section.port),
				tostring(pg_section.port)
			)
		end
		if connections_port ~= pg_port then
			return string.format(
				'service "%s": port mismatch (connections: %d / pg_service: %d)',
				service,
				connections_port,
				pg_port
			)
		end
	end
	return nil
end

return M
