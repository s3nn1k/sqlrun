# sqlrun

Neovim plugin: run SQL files or visual selections through `psql` into a reusable bottom
split.

- Telescope picker over pg services on every run: capture the query first, pick the
  connection, run psql; the choice is not cached.
- psql reads the picked service through `PGSERVICEFILE` set to the expanded
  `pg_service_path`; the rest of the environment is inherited and `pgpass` is left to
  libpq.
- Services from `connections.toml` get a managed port-forward: before each run the plugin
  probes `127.0.0.1:<port>` (up to `probe_timeout_ms` per pass; a cold start can spend two
  passes, a stale forward with a dead owner costs a third recovery pass) and raises the
  section's `pre_cmd` when the port is down; forwards die with their owner session
  (VimEnter sweep, VimLeavePre shutdown).
- Result buffer `sqlrun://result` shows service, source, timing, status; stderr and
  non-zero exits render as errors; output is capped by `max_lines`; `q` closes the window
  and the next run reuses it.

## Dependencies

- `psql` - query execution
- `kubectl` - only for services with a `pre_cmd` port-forward
- nvim-telescope/telescope.nvim - service picker
- plenary.nvim - tests only

## Setup

All `setup()` keys are optional:

- `pg_service_path` - `os.getenv("PGSERVICEFILE") or "~/.pg_service.conf"`
- `connections_path` - `"~/credentials/postgres/connections.toml"`
- `max_lines` - `2000`
- `probe_timeout_ms` - `15000`

The connections file uses INI-style sections despite the `.toml` name: one `[service]`
section per service with `port` and an optional quoted `pre_cmd` - exactly one command
(run via `sh -c exec`, no `&&` or `;`); its port must match the same service in
`pg_service.conf`.

## lazy.nvim spec

```lua
{
	"s3nn1k/sqlrun",
	ft = { "sql" },
	dependencies = { "nvim-telescope/telescope.nvim" },
	keys = {
		{ "<leader>X", function() require("sqlrun").run() end, mode = { "n", "v" }, desc = "sqlrun: run query" },
	},
	init = function()
		local group = vim.api.nvim_create_augroup("SqlrunForwardSweep", { clear = true })
		vim.api.nvim_create_autocmd("VimEnter", {
			group = group,
			callback = function()
				require("sqlrun").sweep()
			end,
		})
		vim.api.nvim_create_autocmd("VimLeavePre", {
			group = group,
			callback = function()
				require("sqlrun").shutdown()
			end,
		})
	end,
}
```

## Gates

- `make fmt` / `make lint` - stylua over `lua/` and `tests/`
- `make test` - plenary busted headless
- `make smoke` - headless `require("sqlrun")` check
