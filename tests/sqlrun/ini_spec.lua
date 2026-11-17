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
		local parsed = ini.parse_ini('[svc]\ndbname = "orders db"\n')
		assert.same("orders db", parsed.svc.dbname)
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

describe("read_pg_service", function()
	it("skips unsafe section names with one warning and keeps valid ones", function()
		local path = vim.fs.normalize(vim.fn.tempname())
		vim.fn.writefile({ "[ok-one]", "port=1", "[../evil]", "port=2" }, path)
		local warns = {}
		local original_notify = vim.notify
		vim.notify = function(message, level)
			if level == vim.log.levels.WARN then
				table.insert(warns, message)
			end
		end
		local sections = ini.read_pg_service(path)
		vim.notify = original_notify
		assert.same({ port = "1" }, sections["ok-one"])
		assert.is_nil(sections["../evil"])
		assert.same(1, #warns)
		assert.truthy(warns[1]:find("../evil", 1, true))
		vim.fn.delete(path)
	end)

	it("returns nothing for a missing file", function()
		assert.is_nil(ini.read_pg_service(vim.fs.normalize(vim.fn.tempname()) .. "/absent.conf"))
	end)

	it("warns once per file path per session", function()
		local path = vim.fs.normalize(vim.fn.tempname())
		vim.fn.writefile({ "[../evil]", "port=1" }, path)
		local warns = {}
		local original_notify = vim.notify
		vim.notify = function(message, level)
			if level == vim.log.levels.WARN then
				table.insert(warns, message)
			end
		end
		ini.read_pg_service(path)
		ini.read_pg_service(path)
		ini.read_pg_service(path)
		vim.notify = original_notify
		assert.same(1, #warns)
		vim.fn.delete(path)
	end)
end)
