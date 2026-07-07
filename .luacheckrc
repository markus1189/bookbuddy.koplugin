-- Copied/trimmed from KOReader's .luacheckrc, since this plugin runs inside
-- KOReader and shares its runtime (LuaJIT) and globals.
unused_args = false
std = "luajit"
-- .direnv is the Nix flake-input tree (direnv `use flake`); it's generated and
-- full of unrelated vendored Lua. Don't lint our own code against its noise.
exclude_files = { ".direnv" }
-- ignore implicit self
self = false

-- Cyclomatic-complexity ceiling (W561). Every function must stay at or below 25.
-- No shipped function is grandfathered: the 8 that once exceeded this (in
-- bbanthropic, bbsubagents, bbtranscript, bbconversation x2, bbtools x3) were
-- refactored under the ceiling and their inline exemptions retired. If a new
-- function genuinely can't be split, an escape hatch remains — a per-function
-- `-- luacheck: max cyclomatic complexity N` fence pinned to its current value,
-- so it's individually ratcheted: touch it and push it higher and the gate
-- trips. Prefer splitting; treat a fence as debt to drive back down.
max_cyclomatic_complexity = 25

globals = {
    "G_reader_settings",
    "G_defaults",
    "table.pack",
    "table.unpack",
}

read_globals = {
    "_ENV",
}

-- Test scaffolding grandfathered at the file level (not shipped code): the
-- Tier-3 eval driver's top-level script and the SSE test validator are branchy
-- by nature. Pinned to today's value so they can't silently get worse either.
files["tests/eval/tier3_driver.lua"] = { max_cyclomatic_complexity = 44 }
files["tests/support/sse.lua"] = { max_cyclomatic_complexity = 32 }

ignore = {
    "211/__*", -- Unused local variable
    "231/__",  -- Local variable is set but never accessed
    "631",     -- Line is too long
    "dummy",
}
