.PHONY: fmt lint test smoke

fmt:
	stylua lua tests

lint:
	stylua --check lua tests

test:
	nvim -n --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/sqlrun"

smoke:
	nvim --headless -u tests/minimal_init.lua +'lua require("sqlrun")' +qa
