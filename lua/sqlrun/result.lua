local M = {}

local buffer_name = "sqlrun://result"

local function result_timestamp()
	return os.date("%Y%m%d-%H%M%S")
end

function M.default_result_path(service, source, data_dir, timestamp)
	local stamp = type(timestamp) == "function" and timestamp() or timestamp
	if type(source) == "string" and source ~= "(selection)" and vim.fn.fnamemodify(source, ":e") ~= "" then
		local stem = vim.fn.fnamemodify(source, ":t:r")
		local dir = vim.fn.fnamemodify(source, ":h")
		return vim.fs.joinpath(dir, stem .. "." .. service .. ".result.txt")
	end
	vim.fn.mkdir(data_dir, "p")
	return vim.fs.joinpath(data_dir, stamp .. "." .. service .. ".result.txt")
end

function M.save_to(path, buf)
	vim.fn.writefile(vim.api.nvim_buf_get_lines(buf, 0, -1, false), path)
end

local function save_result(buf)
	local ok, err = pcall(function()
		local data_dir = vim.fs.joinpath(vim.fn.stdpath("data"), "sqlrun")
		local default_path =
			M.default_result_path(vim.b[buf].sqlrun_service, vim.b[buf].sqlrun_source, data_dir, result_timestamp)
		vim.ui.input({ prompt = "sqlrun: save result to: ", default = default_path }, function(chosen)
			if not chosen or chosen == "" then
				return
			end
			local written, write_err = pcall(M.save_to, chosen, buf)
			if not written then
				vim.notify("sqlrun: cannot save result: " .. tostring(write_err), vim.log.levels.ERROR)
				return
			end
			vim.notify("sqlrun: saved: " .. chosen, vim.log.levels.INFO)
		end)
	end)
	if not ok then
		vim.notify("sqlrun: cannot save result: " .. tostring(err), vim.log.levels.ERROR)
	end
end

local function ensure_buffer()
	local buf = vim.fn.bufnr(buffer_name)
	if buf > 0 then
		return buf
	end
	buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(buf, buffer_name)
	vim.bo[buf].bufhidden = "hide"
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].filetype = "sqlrun"
	vim.bo[buf].swapfile = false
	vim.keymap.set("n", "q", function()
		local win = vim.fn.win_findbuf(buf)[1]
		if win and vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_close(win, true)
		end
	end, { buffer = buf, desc = "sqlrun: close result" })
	vim.keymap.set("n", "<C-s>", function()
		save_result(buf)
	end, { buffer = buf, desc = "sqlrun: save result" })
	return buf
end

local function open_window(buf)
	for _, win in ipairs(vim.fn.win_findbuf(buf)) do
		if vim.api.nvim_win_is_valid(win) then
			return win
		end
	end
	local current = vim.api.nvim_get_current_win()
	return vim.api.nvim_open_win(buf, false, { split = "below", win = current })
end

local function render(lines, service, source)
	local buf = ensure_buffer()
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
	vim.bo[buf].modified = false
	vim.b[buf].sqlrun_service = service
	vim.b[buf].sqlrun_source = source
	local win = open_window(buf)
	pcall(vim.api.nvim_win_set_cursor, win, { 1, 0 })
	return win
end

function M.truncate_lines(lines, max_lines)
	if not max_lines or max_lines <= 0 or #lines <= max_lines then
		return { lines = lines, truncated = false }
	end
	return { lines = vim.list_slice(lines, 1, max_lines), truncated = true }
end

function M.open()
	return open_window(ensure_buffer())
end

function M.show_running(service, source)
	return render({
		"-- service: " .. service .. " | source: " .. source .. " | status: running...",
		"",
	}, service, source)
end

function M.show(done)
	local lines = vim.split(done.stdout or "", "\n", { trimempty = true })
	local failed = done.code ~= 0
	if (done.stderr or "") ~= "" then
		local stderr_lines = vim.split(done.stderr, "\n", { trimempty = true })
		if failed then
			vim.list_extend(lines, stderr_lines)
		else
			for _, stderr_line in ipairs(stderr_lines) do
				table.insert(lines, "-- " .. stderr_line)
			end
		end
	end
	local cut = M.truncate_lines(lines, done.max_lines)
	if cut.truncated then
		table.insert(cut.lines, "-- output truncated to " .. done.max_lines .. " lines")
	end
	local status = failed and ("error (exit " .. done.code .. ")") or "ok"
	local header = "-- service: "
		.. done.service
		.. " | source: "
		.. done.source
		.. " | time: "
		.. string.format("%.3fs", done.elapsed_seconds)
		.. " | status: "
		.. status
	return render(vim.list_extend({ header, "" }, cut.lines), done.service, done.source)
end

return M
