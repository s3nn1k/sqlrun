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
