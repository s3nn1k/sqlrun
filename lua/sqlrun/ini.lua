local M = {}

local function strip_quotes(value)
	if #value >= 2 and value:sub(1, 1) == '"' and value:sub(-1) == '"' then
		return value:sub(2, -2)
	end
	return value
end

function M.parse_ini(text)
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

local function expand(path)
	return vim.fs.normalize(vim.fn.expand(path))
end

local function read_ini(path)
	local file = io.open(path, "r")
	if not file then
		return nil
	end
	local text = file:read("*a")
	file:close()
	return M.parse_ini(text)
end

function M.read_pg_service(path)
	return read_ini(expand(path or os.getenv("PGSERVICEFILE") or "~/.pg_service.conf"))
end

function M.read_connections(path)
	return read_ini(expand(path or "~/credentials/postgres/connections.toml"))
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
