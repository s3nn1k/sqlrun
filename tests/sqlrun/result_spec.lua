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

	it("makes the buffer read-only after rendering", function()
		result.show({
			service = "svc",
			source = "q.sql",
			elapsed_seconds = 0.01,
			code = 0,
			stdout = "ok",
			stderr = "",
			max_lines = 100,
		})
		local buf = vim.fn.bufnr("sqlrun://result")
		assert.is_false(vim.bo[buf].modifiable)
	end)

	it("clears the modified flag after rendering", function()
		result.show({
			service = "svc",
			source = "q.sql",
			elapsed_seconds = 0.1,
			code = 0,
			stdout = "ok",
			stderr = "",
			max_lines = 100,
		})
		local buf = vim.fn.bufnr("sqlrun://result")
		assert.is_true(buf > 0)
		assert.is_false(vim.bo[buf].modified)
		vim.cmd("bd " .. buf)
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

describe("default_result_path", function()
	it("puts the file next to a file source with the service inserted", function()
		local path = result.default_result_path("svc", "/tmp/queries/q.sql", "/tmp/data", "20260102-030405")
		assert.equals("/tmp/queries/q.svc.result.txt", path)
	end)

	it("falls back to a timestamped file in the data dir for a selection", function()
		local data_dir = vim.fn.tempname() .. "-data"
		local path = result.default_result_path("svc", "(selection)", data_dir, function()
			return "20260102-030405"
		end)
		assert.equals(data_dir .. "/20260102-030405.svc.result.txt", path)
	end)
end)

describe("save_to", function()
	it("writes the exact rendered lines from the read-only buffer", function()
		result.show({
			service = "svc",
			source = "q.sql",
			elapsed_seconds = 0.01,
			code = 0,
			stdout = "row1\nrow2",
			stderr = "",
			max_lines = 2000,
		})
		local buf = vim.fn.bufnr("sqlrun://result")
		assert.is_false(vim.bo[buf].modifiable)
		local path = vim.fn.tempname() .. ".result.txt"
		result.save_to(path, buf)
		assert.same(vim.api.nvim_buf_get_lines(buf, 0, -1, false), vim.fn.readfile(path))
		os.remove(path)
	end)
end)

describe("save flow", function()
	local original_input
	local original_notify
	local notified

	before_each(function()
		original_input = vim.ui.input
		original_notify = vim.notify
		notified = nil
		vim.notify = function(message, level)
			notified = { message = message, level = level }
		end
	end)

	after_each(function()
		vim.ui.input = original_input
		vim.notify = original_notify
		local buf = vim.fn.bufnr("sqlrun://result")
		if buf > 0 then
			for _, win in ipairs(vim.fn.win_findbuf(buf)) do
				pcall(vim.api.nvim_win_close, win, true)
			end
			pcall(vim.api.nvim_buf_delete, buf, { force = true })
		end
	end)

	local function press_save()
		local buf = vim.fn.bufnr("sqlrun://result")
		local win = vim.fn.win_findbuf(buf)[1]
		vim.api.nvim_set_current_win(win)
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-s>", true, false, true), "mx", false)
	end

	local function show_result()
		result.show({
			service = "svc",
			source = "/tmp/queries/q.sql",
			elapsed_seconds = 0.01,
			code = 0,
			stdout = "row1",
			stderr = "",
			max_lines = 2000,
		})
		return vim.fn.bufnr("sqlrun://result")
	end

	it("offers the query file's dir and service in the prompt", function()
		local input_opts
		vim.ui.input = function(opts, on_confirm)
			input_opts = opts
			on_confirm(nil)
		end
		local buf = show_result()
		assert.is_false(vim.bo[buf].modifiable)
		press_save()
		assert.equals("sqlrun: save result to: ", input_opts.prompt)
		assert.equals("/tmp/queries/q.svc.result.txt", input_opts.default)
	end)

	it("creates no file when the prompt is cancelled", function()
		local input_opts
		vim.ui.input = function(opts, on_confirm)
			input_opts = opts
			on_confirm(nil)
		end
		show_result()
		press_save()
		assert.is_nil(vim.uv.fs_stat(input_opts.default))
	end)

	it("writes the chosen file and notifies on confirm", function()
		local path = vim.fn.tempname() .. ".svc.result.txt"
		vim.ui.input = function(_, on_confirm)
			on_confirm(path)
		end
		local buf = show_result()
		press_save()
		assert.equals(1, vim.fn.filereadable(path))
		assert.same(vim.api.nvim_buf_get_lines(buf, 0, -1, false), vim.fn.readfile(path))
		assert.equals(vim.log.levels.INFO, notified.level)
		assert.truthy(notified.message:find(path, 1, true))
		os.remove(path)
	end)

	it("notifies an error and skips the file when writing fails", function()
		local path = vim.fs.joinpath(vim.fn.tempname() .. "-missing", "q.svc.result.txt")
		vim.ui.input = function(_, on_confirm)
			on_confirm(path)
		end
		show_result()
		press_save()
		assert.equals(vim.log.levels.ERROR, notified.level)
		assert.is_nil(vim.uv.fs_stat(path))
	end)
end)
