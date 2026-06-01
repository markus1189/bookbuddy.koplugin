-- Minimal busted helper for the hermetic real-crengine harness (.#test-real).
-- Stands in for koreader-base's test-runner/busted_helper.lua so the flake needs
-- only the koreader *main* source (no koreader-base submodule). The upstream
-- helper exists to preload busted modules and strip `spec/rocks/` from the Lua
-- path; we run busted from a nixpkgs luaEnv that is never under spec/rocks, so
-- both are no-ops here. The two things that DO matter:
--   1. create $KO_HOME before DataStorage (via commonrequire) writes into it;
--   2. install koreader's ffi.loadlib shim that its FFI library loader relies on.
local lfs = require("libs/libkoreader-lfs")
lfs.mkdir(os.getenv("KO_HOME"))
require("ffi/loadlib")
