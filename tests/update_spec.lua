-- Unit checks for bbupdate's file-local semver/url helpers, reached via the
-- test-only Updater._test export. Requiring bbupdate pulls in device/uimanager/
-- widgets/gettext/ffi-util, covered by stubs.install() plus a couple of inline
-- doubles below; no network or device is touched (these helpers are pure).
local stubs = require("support.stubs")

describe("bbupdate helpers", function()
    local U

    setup(function()
        stubs.install()
        -- bbupdate also requires "device" and "ui/widget/confirmbox", which the
        -- shared stubs don't cover (they're only needed by this module).
        package.loaded["device"] = {
            canOpenLink = function()
                return false
            end,
        }
        package.loaded["ui/widget/confirmbox"] = {
            new = function(_, o)
                return o or {}
            end,
        }
        U = require("bbupdate")._test
    end)

    describe("parseVersion", function()
        it("splits dotted numerics into a parts array", function()
            assert.are.same({ 1, 2, 3 }, U.parseVersion("1.2.3"))
        end)

        it("strips a leading v", function()
            assert.are.same({ 2, 0 }, U.parseVersion("v2.0"))
        end)

        it("coerces non-numeric parts to 0", function()
            assert.are.same({ 1, 0, 5 }, U.parseVersion("1.x.5"))
        end)

        it("takes the leading digit run of a suffixed component", function()
            assert.are.same({ 1, 13, 3 }, U.parseVersion("1.13.3-beta"))
        end)
    end)

    describe("isNewer", function()
        it("is true when the first version is greater", function()
            assert.is_true(U.isNewer("1.0.1", "1.0.0"))
            assert.is_true(U.isNewer("1.1", "1.0.9"))
            assert.is_true(U.isNewer("2.0", "1.9.9"))
        end)

        it("is false for equal versions", function()
            assert.is_false(U.isNewer("1.2.3", "1.2.3"))
        end)

        it("is false when the first version is older", function()
            assert.is_false(U.isNewer("1.0.0", "1.0.1"))
        end)

        it("treats missing trailing components as zero", function()
            assert.is_false(U.isNewer("1.0", "1.0.0"))
            assert.is_true(U.isNewer("1.0.1", "1.0"))
        end)
    end)

    describe("composeBranchZipUrl", function()
        it("builds the GitHub zipball URL for the main branch", function()
            assert.are.equal(
                "https://api.github.com/repos/markus1189/bookbuddy.koplugin/zipball/main",
                U.composeBranchZipUrl()
            )
        end)
    end)

    describe("extractPlugin", function()
        local lfs = require("lfs")
        local root, plugin, Device, extracted_from

        local function rmtree(dir)
            for name in lfs.dir(dir) do
                if name ~= "." and name ~= ".." then
                    local p = dir .. "/" .. name
                    if lfs.attributes(p, "mode") == "directory" then
                        rmtree(p)
                    else
                        os.remove(p)
                    end
                end
            end
            lfs.rmdir(dir)
        end

        local function mkdirs(path)
            local cur = ""
            for part in path:gmatch("[^/]+") do
                cur = cur .. "/" .. part
                lfs.mkdir(cur)
            end
        end

        local function write(path, content)
            mkdirs(path:match("^(.*)/[^/]+$"))
            local f = assert(io.open(path, "w"))
            f:write(content)
            f:close()
        end

        local function read(path)
            local f = io.open(path)
            if not f then
                return nil
            end
            local c = f:read("*a")
            f:close()
            return c
        end

        -- Mirrors ffi/archiver's Reader surface (open/iterate/extractToPath/close/err)
        -- over an in-memory entry list; fail_at makes that entry's extraction fail.
        local function fakeArchiver(entries, fail_at)
            return {
                Reader = {
                    new = function()
                        local r = {}
                        function r:open(path)
                            extracted_from = path
                            return true
                        end
                        function r:iterate()
                            local i = 0
                            return function()
                                i = i + 1
                                return entries[i]
                            end
                        end
                        function r:extractToPath(key, dest)
                            if key == fail_at then
                                self.err = "corrupt entry"
                                return false
                            end
                            for _, e in ipairs(entries) do
                                if e.path == key then
                                    if e.mode == "directory" then
                                        mkdirs(dest)
                                    else
                                        write(dest, e.content)
                                    end
                                end
                            end
                            return true
                        end
                        function r:close() end
                        return r
                    end,
                },
            }
        end

        local ZIPBALL = {
            { path = "owner-repo-abc123/", mode = "directory" },
            { path = "owner-repo-abc123/_meta.lua", mode = "file", content = "new meta" },
            { path = "owner-repo-abc123/tests/", mode = "directory" },
            { path = "owner-repo-abc123/tests/x_spec.lua", mode = "file", content = "spec" },
        }

        before_each(function()
            root = os.tmpname()
            os.remove(root)
            lfs.mkdir(root)
            plugin = root .. "/bookbuddy.koplugin"
            write(plugin .. "/_meta.lua", "old meta")
            write(plugin .. "/stale.lua", "gone after update")
            package.loaded["libs/libkoreader-lfs"] = lfs
            package.loaded["ffi/util"].purgeDir = function(dir)
                rmtree(dir)
                return true
            end
            Device = package.loaded["device"]
            Device.unpackArchive = nil
            extracted_from = nil
        end)

        after_each(function()
            package.loaded["ffi/archiver"] = nil
            rmtree(root)
        end)

        it("swaps in the archive's contents with the zipball root stripped", function()
            package.loaded["ffi/archiver"] = fakeArchiver(ZIPBALL)
            assert.is_true(U.extractPlugin("/tmp/u.zip", plugin))
            assert.are.equal("/tmp/u.zip", extracted_from)
            assert.are.equal("new meta", read(plugin .. "/_meta.lua"))
            assert.are.equal("spec", read(plugin .. "/tests/x_spec.lua"))
            assert.is_nil(read(plugin .. "/stale.lua"))
            assert.is_nil(lfs.attributes(plugin .. ".new"))
            assert.is_nil(lfs.attributes(plugin .. ".old"))
        end)

        it("keeps the old install when the archive has no _meta.lua", function()
            package.loaded["ffi/archiver"] = fakeArchiver({ ZIPBALL[1], ZIPBALL[3], ZIPBALL[4] })
            local ok, err = U.extractPlugin("/tmp/u.zip", plugin)
            assert.is_false(ok)
            assert.matches("_meta.lua", err)
            assert.are.equal("old meta", read(plugin .. "/_meta.lua"))
            assert.is_nil(lfs.attributes(plugin .. ".new"))
        end)

        it("keeps the old install when an entry fails to extract", function()
            package.loaded["ffi/archiver"] = fakeArchiver(ZIPBALL, "owner-repo-abc123/tests/x_spec.lua")
            local ok, err = U.extractPlugin("/tmp/u.zip", plugin)
            assert.is_false(ok)
            assert.are.equal("corrupt entry", err)
            assert.are.equal("old meta", read(plugin .. "/_meta.lua"))
            assert.are.equal("gone after update", read(plugin .. "/stale.lua"))
            assert.is_nil(lfs.attributes(plugin .. ".new"))
        end)

        it("falls back to Device:unpackArchive on KOReader without ffi/archiver", function()
            local args
            Device.unpackArchive = function(_, ...)
                args = { ... }
                return true
            end
            assert.is_true(U.extractPlugin("/tmp/u.zip", plugin))
            assert.are.same({ "/tmp/u.zip", plugin, true }, args)
        end)
    end)
end)
