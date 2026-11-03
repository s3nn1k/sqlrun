local ini = require("sqlrun.ini")

describe("parse_ini", function()
	it("parses sections into key tables", function()
		local parsed = ini.parse_ini([[
[alpha]
host = h1
port = 5432

[beta]
host = h2
]])
		assert.same({ alpha = { host = "h1", port = "5432" }, beta = { host = "h2" } }, parsed)
	end)

	it("strips surrounding double quotes from values", function()
		local parsed = ini.parse_ini('[svc]\npre_cmd = "kubectl port-forward svc/x 15432:5432"\n')
		assert.same("kubectl port-forward svc/x 15432:5432", parsed.svc.pre_cmd)
	end)

	it("skips comments and empty lines", function()
		local parsed = ini.parse_ini("# top\n; also\n\n[svc]\n# inner\nport=15432\n\n")
		assert.same({ svc = { port = "15432" } }, parsed)
	end)

	it("strips a leading UTF-8 BOM", function()
		local parsed = ini.parse_ini("\239\187\191[svc]\nport=15432\n")
		assert.same({ svc = { port = "15432" } }, parsed)
	end)

	it("ignores lines before the first section", function()
		local parsed = ini.parse_ini("orphan=1\n[svc]\nport=1\n")
		assert.same({ svc = { port = "1" } }, parsed)
		assert.is_nil(parsed.orphan)
	end)
end)

describe("parse_port", function()
	it("parses a numeric port", function()
		assert.same(15432, ini.parse_port({ port = "15432" }))
		assert.same(5432, ini.parse_port({ port = 5432 }))
	end)

	it("returns nil for missing port", function()
		assert.is_nil(ini.parse_port({ host = "h" }))
		assert.is_nil(ini.parse_port({}))
	end)

	it("returns nil for garbage port", function()
		assert.is_nil(ini.parse_port({ port = "abc" }))
	end)

	it("returns nil for out-of-range or fractional ports", function()
		assert.is_nil(ini.parse_port({ port = 0 }))
		assert.is_nil(ini.parse_port({ port = 70000 }))
		assert.is_nil(ini.parse_port({ port = 1.5 }))
	end)
end)

describe("config readers", function()
	it("rejects invalid section names with the section in the error", function()
		local path = vim.fs.normalize(vim.fn.tempname())
		vim.fn.writefile({ "[ok-one]", "port=1", "[../evil]", "port=2" }, path)
		local sections, err = ini.read_connections(path)
		assert.is_nil(sections)
		assert.truthy(err:find("../evil", 1, true))
		vim.fn.delete(path)
	end)

	it("returns nothing for a missing file without an error", function()
		local sections, err = ini.read_connections(vim.fs.normalize(vim.fn.tempname()) .. "/absent.toml")
		assert.is_nil(sections)
		assert.is_nil(err)
	end)
end)

describe("validate_consistency", function()
	local connections = { work = { port = "15432" } }

	it("passes when ports match", function()
		assert.is_nil(ini.validate_consistency(connections, { work = { port = "15432" } }))
	end)

	it("reports mismatch with service and both ports", function()
		local err = ini.validate_consistency(connections, { work = { port = "5433" } })
		assert.truthy(err:find("work"))
		assert.truthy(err:find("15432"))
		assert.truthy(err:find("5433"))
	end)

	it("reports a missing pg_service section", function()
		local err = ini.validate_consistency(connections, { other = { port = "15432" } })
		assert.truthy(err:find("work"))
	end)

	it("reports an invalid port", function()
		local err = ini.validate_consistency({ work = { port = "oops" } }, { work = { port = "15432" } })
		assert.truthy(err:find("oops"))
		assert.truthy(err:find("15432"))
	end)

	it("reports unreadable inputs", function()
		assert.truthy(ini.validate_consistency(nil, {}))
		assert.truthy(ini.validate_consistency({}, nil))
	end)
end)
