# sqlrun

Neovim plugin: run SQL files or visual selections through `psql` into a reusable bottom
split.

- Telescope picker over pg services on every run: capture the query first, pick the
  connection, run psql; the choice is not cached.
- psql reads the picked service through `PGSERVICEFILE` set to the expanded
  `pg_service_path`; the rest of the environment is inherited and `pgpass` is left to
  libpq.
- Result buffer `sqlrun://result` shows service, source, timing, status; stderr and
  non-zero exits render as errors; output is capped by `max_lines`; `q` closes the window
  and the next run reuses it. The buffer is read-only; `<C-s>` saves it to a file - next
  to the query file by default (`<query>.<service>.result.txt`), timestamped under
  `stdpath("data")/sqlrun` for selections; the path is editable in the prompt.

## Requirements

- Neovim >= 0.10

## Dependencies

- `psql` - query execution
- nvim-telescope/telescope.nvim - service picker
- plenary.nvim - tests only

## Setup

All `setup()` keys are optional:

- `pg_service_path` - `os.getenv("PGSERVICEFILE") or "~/.pg_service.conf"`
- `max_lines` - `2000`
- `result_keymaps` - `{ close = "q", save = "<C-s>" }`; each field is a buffer-local key
  lhs string, or `false` to not create the map

## lazy.nvim spec

```lua
{
	"s3nn1k/sqlrun",
	version = "*",
	ft = { "sql" },
	dependencies = { "nvim-telescope/telescope.nvim" },
	keys = {
		{ "<leader>X", function() require("sqlrun").run() end, mode = { "n", "v" }, desc = "sqlrun: run query" },
	},
}
```

## Events

Every run emits two `User` events: `SqlrunRunStart` right after the service is picked and
`SqlrunRunDone` when the run finishes - after the result is rendered, or as soon as it
fails. `vim.g.sqlrun_last_status` carries the done status ("ok" or "error").

## Gates

- `make fmt` / `make lint` - stylua over `lua/` and `tests/`
- `make test` - plenary busted headless
- `make smoke` - headless `require("sqlrun")` check
