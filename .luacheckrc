-- Copied/trimmed from KOReader's .luacheckrc, since this plugin runs inside
-- KOReader and shares its runtime (LuaJIT) and globals.
unused_args = false
std = "luajit"
-- .direnv is the Nix flake-input tree (direnv `use flake`); it's generated and
-- full of unrelated vendored Lua. Don't lint our own code against its noise.
exclude_files = { ".direnv" }
-- ignore implicit self
self = false

globals = {
    "G_reader_settings",
    "G_defaults",
    "table.pack",
    "table.unpack",
}

read_globals = {
    "_ENV",
}

ignore = {
    "211/__*", -- Unused local variable
    "231/__",  -- Local variable is set but never accessed
    "631",     -- Line is too long
    "dummy",
}
