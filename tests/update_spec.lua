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
end)
