local result = require("sqlrun.result")

describe("truncate_lines", function()
	it("keeps output within the limit untouched", function()
		local cut = result.truncate_lines({ "a", "b", "c" }, 2000)
		assert.same({ "a", "b", "c" }, cut.lines)
		assert.is_false(cut.truncated)
	end)

	it("keeps exactly max_lines without the flag", function()
		local lines = {}
		for index = 1, 2000 do
			lines[index] = "line-" .. index
		end
		local cut = result.truncate_lines(lines, 2000)
		assert.same(2000, #cut.lines)
		assert.is_false(cut.truncated)
	end)

	it("cuts to max_lines and flags the truncation", function()
		local lines = {}
		for index = 1, 2500 do
			lines[index] = "line-" .. index
		end
		local cut = result.truncate_lines(lines, 2000)
		assert.same(2000, #cut.lines)
		assert.same("line-2000", cut.lines[2000])
		assert.is_true(cut.truncated)
	end)
end)

describe("show", function()
	local original_notify

	before_each(function()
		original_notify = vim.notify
		vim.notify = function() end
	end)

	after_each(function()
		vim.notify = original_notify
		local buf = vim.fn.bufnr("sqlrun://result")
		if buf > 0 then
			for _, win in ipairs(vim.fn.win_findbuf(buf)) do
				pcall(vim.api.nvim_win_close, win, true)
			end
			pcall(vim.api.nvim_buf_delete, buf, { force = true })
		end
	end)

	local function buffer_text()
		local buf = vim.fn.bufnr("sqlrun://result")
		return table.concat(vim.fn.getbufline(buf, 1, "$"), "\n")
	end

	it("renders stderr as notices and keeps status ok on exit zero", function()
		result.show({
			service = "svc",
			source = "q.sql",
			elapsed_seconds = 0.01,
			code = 0,
			stdout = "a\nb\n",
			stderr = "NOTICE: ddl committed\n",
			max_lines = 2000,
		})
		local text = buffer_text()
		assert.truthy(text:find("status: ok"))
		assert.truthy(text:find("%-%- NOTICE: ddl committed"))
	end)

	it("flips status to error on non-zero exit", function()
		result.show({
			service = "svc",
			source = "q.sql",
			elapsed_seconds = 0.01,
			code = 2,
			stdout = "",
			stderr = "boom\n",
			max_lines = 2000,
		})
		local text = buffer_text()
		assert.truthy(text:find("status: error %(exit 2%)"))
		assert.truthy(text:find("boom"))
	end)
end)
