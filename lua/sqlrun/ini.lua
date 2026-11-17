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

function M.valid_service_name(name)
	return type(name) == "string" and name:match(service_name_pattern) ~= nil
end

local function expand(path)
	return vim.fs.normalize(vim.fn.expand(path))
end

local warned_paths = {}

local function sanitize_sections(sections, path)
	local valid = {}
	local unsafe = {}
	for name, section in pairs(sections) do
		if M.valid_service_name(name) then
			valid[name] = section
		else
			table.insert(unsafe, name)
		end
	end
	if #unsafe > 0 and not warned_paths[path] then
		warned_paths[path] = true
		table.sort(unsafe)
		local listed = vim.tbl_map(function(name)
			return '"' .. name .. '"'
		end, unsafe)
		vim.notify(
			"sqlrun: skipping services with unsafe names in pg_service: " .. table.concat(listed, ", "),
			vim.log.levels.WARN
		)
	end
	return valid
end

function M.read_pg_service(path)
	path = expand(path or os.getenv("PGSERVICEFILE") or "~/.pg_service.conf")
	local file = io.open(path, "r")
	if not file then
		return nil
	end
	local text = file:read("*a")
	file:close()
	return sanitize_sections(M.parse_ini(text), path)
end

return M
