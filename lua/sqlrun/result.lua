local M = {}

local buffer_name = "sqlrun://result"

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

local function render(lines)
	local buf = ensure_buffer()
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modified = false
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
	})
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
	return render(vim.list_extend({ header, "" }, cut.lines))
end

return M
