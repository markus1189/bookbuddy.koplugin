local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

-- Where self-updates come from. The repo root must be the plugin folder, and
-- it must be public so the raw _meta.lua and the zipball are fetchable without
-- a token. Change BRANCH if the repo's default branch is not "main".
local REPO = "markus1189/bookbuddy.koplugin"
local BRANCH = "main"

local Updater = {}

function Updater.getInstalledVersion()
    local DataStorage = require("datastorage")
    local meta_path = DataStorage:getDataDir() .. "/plugins/bookbuddy.koplugin/_meta.lua"
    local ok_meta, meta = pcall(dofile, meta_path)
    return (ok_meta and meta and meta.version) or "unknown"
end

local function parseVersion(v)
    local parts = {}
    for part in tostring(v):gsub("^v", ""):gmatch("([^.]+)") do
        -- Take the leading digit run so a suffixed component (e.g. "3-beta") parses as 3
        -- rather than collapsing to 0, which would mis-order a pre-release below x.x.0.
        table.insert(parts, tonumber(part:match("^%d+")) or 0)
    end
    return parts
end

local function isNewer(v1, v2)
    local a, b = parseVersion(v1), parseVersion(v2)
    for i = 1, math.max(#a, #b) do
        local x, y = a[i] or 0, b[i] or 0
        if x > y then
            return true
        end
        if x < y then
            return false
        end
    end
    return false
end

-- Try LuaSocket first, fall back to curl for platforms where SSL crashes.
-- Returns the raw response body string, or nil.
local function httpGet(url, user_agent)
    local ok_require, http, ltn12, socket, socketutil = pcall(function()
        return require("socket/http"), require("ltn12"), require("socket"), require("socketutil")
    end)
    if ok_require then
        local body = {}
        local ok_req, code = pcall(function()
            socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
            local c = socket.skip(
                1,
                http.request({
                    url = url,
                    method = "GET",
                    headers = {
                        ["User-Agent"] = user_agent,
                    },
                    sink = ltn12.sink.table(body),
                    redirect = true,
                })
            )
            socketutil:reset_timeout()
            return c
        end)
        if ok_req and code == 200 then
            return table.concat(body)
        end
        pcall(function()
            socketutil:reset_timeout()
        end)
    end
    -- Fallback: curl (available on Android, desktop). -f so an HTTP error (e.g. a
    -- GitHub 404) exits non-zero and yields no body, instead of returning the error
    -- page as a "successful" response the version regex then scans (mirrors install()).
    local handle = io.popen(string.format("curl -sfL -H 'User-Agent: KOReader-BookBuddy' %q", url))
    if handle then
        local body = handle:read("*a")
        handle:close()
        if body and body ~= "" then
            return body
        end
    end
    return nil
end

-- Compose the GitHub branch-archive (zipball) URL. The branch is URL-encoded
-- except for alnum, dash, underscore, dot, tilde and slash.
local function composeBranchZipUrl()
    local encoded = BRANCH:gsub("[^%w%-_/.~]", function(c)
        return string.format("%%%02X", c:byte())
    end)
    return string.format("https://api.github.com/repos/%s/zipball/%s", REPO, encoded)
end

-- Fetch the remote _meta.lua and extract its version string (without executing
-- remote code). Returns the version string or nil.
function Updater.getRemoteVersion()
    local user_agent = "KOReader-BookBuddy/" .. Updater.getInstalledVersion()
    local url = string.format("https://raw.githubusercontent.com/%s/%s/_meta.lua", REPO, BRANCH)
    local body = httpGet(url, user_agent)
    if not body then
        return nil
    end
    return body:match("version%s*=%s*[\"']([%d%.]+)[\"']")
end

function Updater.offerRepoPage(message)
    local url = "https://github.com/" .. REPO
    if Device:canOpenLink() then
        UIManager:show(ConfirmBox:new({
            text = message .. "\n\n" .. _("Open the repository in a browser?"),
            ok_text = _("Open"),
            ok_callback = function()
                Device:openLink(url)
            end,
        }))
    else
        UIManager:show(InfoMessage:new({
            text = message,
            timeout = 3,
        }))
    end
end

function Updater.check()
    -- runWhenOnline attempts to bring Wi-Fi up if it's off (prompting per the
    -- user's KOReader Wi-Fi prefs) and runs the callback once online. If the
    -- user cancels the prompt the callback never fires -- the right cancel UX.
    local NetworkMgr = require("ui/network/manager")
    NetworkMgr:runWhenOnline(function()
        UIManager:show(InfoMessage:new({
            text = _("Checking for updates..."),
            timeout = 1,
        }))
        UIManager:scheduleIn(0.1, function()
            local installed = Updater.getInstalledVersion()
            local remote = Updater.getRemoteVersion()
            if not remote then
                Updater.offerRepoPage(_("Could not check for updates."))
                return
            end
            if not isNewer(remote, installed) then
                UIManager:show(InfoMessage:new({
                    text = T(_("BookBuddy is up to date (v%1)."), installed),
                    timeout = 3,
                }))
                return
            end
            UIManager:show(ConfirmBox:new({
                text = T(_("Update available: v%1 \xE2\x86\x92 v%2.\n\nUpdate and restart?"), installed, remote),
                ok_text = _("Update"),
                ok_callback = function()
                    Updater.install(installed, remote)
                end,
            }))
        end)
    end)
end

-- Unpack the zipball into a sibling staging folder, then swap it in for the live
-- plugin folder, so a failed extraction never leaves a half-updated install.
-- KOReader v2026.07 dropped Device:unpackArchive (koreader 751b49784) and calling
-- it took KOReader down; ffi/archiver replaces it from v2025.08 on.
local function extractPlugin(zip_path, plugin_path)
    local ok_arc, Archiver = pcall(require, "ffi/archiver")
    if not ok_arc then
        return Device:unpackArchive(zip_path, plugin_path, true)
    end
    local lfs = require("libs/libkoreader-lfs")
    local purgeDir = require("ffi/util").purgeDir
    -- The plugin loader only picks up names ending in ".koplugin", so a leftover
    -- staging or backup folder is never loaded as a second copy.
    local staging, backup = plugin_path .. ".new", plugin_path .. ".old"
    for _, dir in ipairs({ staging, backup }) do
        if lfs.attributes(dir, "mode") == "directory" then
            purgeDir(dir)
        end
    end
    if not lfs.mkdir(staging) then
        return false, "cannot create " .. staging
    end

    local err
    local arc = Archiver.Reader:new()
    if arc:open(zip_path) then
        for entry in arc:iterate() do
            -- Zipball entries sit under a single "<owner>-<repo>-<sha>/" root; strip it.
            local rel = entry.path:match("^[^/]+/(.+)$")
            if rel and not arc:extractToPath(entry.path, staging .. "/" .. rel) then
                err = arc.err or ("cannot extract " .. rel)
                break
            end
        end
        err = err or arc.err
    else
        err = arc.err or "cannot open the downloaded archive"
    end
    arc:close()
    if not err and lfs.attributes(staging .. "/_meta.lua", "mode") ~= "file" then
        err = "the downloaded archive has no _meta.lua"
    end
    if err then
        purgeDir(staging)
        return false, err
    end

    local had_old = lfs.attributes(plugin_path, "mode") == "directory"
    if had_old then
        local ok, rename_err = os.rename(plugin_path, backup)
        if not ok then
            purgeDir(staging)
            return false, rename_err
        end
    end
    local ok, rename_err = os.rename(staging, plugin_path)
    if not ok then
        if had_old then
            os.rename(backup, plugin_path)
        end
        purgeDir(staging)
        return false, rename_err
    end
    if had_old then
        purgeDir(backup)
    end
    return true
end

function Updater.install(old_version, new_version)
    UIManager:show(InfoMessage:new({
        text = _("Downloading update..."),
        timeout = 1,
    }))

    UIManager:scheduleIn(0.1, function()
        local ok_install, install_err = pcall(Updater._doInstall, old_version, new_version)
        if not ok_install then
            logger.err("BookBuddy: update failed:", install_err)
            UIManager:show(InfoMessage:new({
                text = _("Installation failed: ") .. tostring(install_err),
                timeout = 5,
            }))
        end
    end)
end

-- The download+install body of Updater.install, run from its scheduled callback.
-- An error escaping a UIManager callback takes KOReader down, hence the pcall there.
function Updater._doInstall(old_version, new_version)
    local DataStorage = require("datastorage")
    local lfs = require("libs/libkoreader-lfs")
    -- Download zipball to a temp location
    local cache_dir = DataStorage:getSettingsDir() .. "/bookbuddy_cache"
    if lfs.attributes(cache_dir, "mode") ~= "directory" then
        lfs.mkdir(cache_dir)
    end
    local zip_path = cache_dir .. "/bookbuddy.koplugin.zip"
    local zip_url = composeBranchZipUrl()

    -- Try LuaSocket first, fall back to curl
    local downloaded = false
    local ok_require, http, ltn12, socket, socketutil = pcall(function()
        return require("socket/http"), require("ltn12"), require("socket"), require("socketutil")
    end)
    if ok_require then
        local file = io.open(zip_path, "wb")
        if file then
            local ok_dl, code = pcall(function()
                socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
                local c = socket.skip(
                    1,
                    http.request({
                        url = zip_url,
                        method = "GET",
                        headers = {
                            ["User-Agent"] = "KOReader-BookBuddy/" .. old_version,
                        },
                        sink = ltn12.sink.file(file),
                        redirect = true,
                    })
                )
                socketutil:reset_timeout()
                return c
            end)
            if not ok_dl then
                pcall(function()
                    socketutil:reset_timeout()
                end)
            end
            -- ltn12.sink.file only closes the handle on the terminating nil chunk;
            -- if the transfer threw (the SSL-crash path this curl fallback exists
            -- for) that chunk never arrives, leaking an open write handle onto the
            -- very path curl is about to re-download. Close it explicitly first;
            -- a double-close of an already-closed handle is harmless under pcall.
            pcall(function()
                file:close()
            end)
            downloaded = ok_dl and code == 200
        end
    end
    -- Fallback: curl. The -f flag makes curl exit non-zero on HTTP errors,
    -- so a 404 body is not written to the zip and mis-reported as an
    -- extraction failure later.
    if not downloaded then
        pcall(os.remove, zip_path)
        local ret = os.execute(string.format("curl -sfL -o %q %q", zip_path, zip_url))
        downloaded = ret == 0 or ret == true
    end
    if not downloaded then
        pcall(os.remove, zip_path)
        Updater.offerRepoPage(_("Download failed."))
        return
    end

    local plugin_path = DataStorage:getDataDir() .. "/plugins/bookbuddy.koplugin"
    local ok, err = extractPlugin(zip_path, plugin_path)
    pcall(os.remove, zip_path)

    if not ok then
        UIManager:show(InfoMessage:new({
            text = _("Installation failed: ") .. tostring(err),
            timeout = 5,
        }))
        return
    end

    -- Restart KOReader to load the new version. Where it can't restart itself
    -- (Android: canRestart = no), restartKOReader only quits, so say so instead.
    if not Device:canRestart() then
        UIManager:show(InfoMessage:new({
            text = T(_("BookBuddy updated to v%1.\n\nClose and reopen KOReader to finish."), new_version),
        }))
        return
    end
    UIManager:show(ConfirmBox:new({
        text = T(_("BookBuddy updated to v%1.\n\nRestart KOReader now?"), new_version),
        ok_text = _("Restart"),
        ok_callback = function()
            UIManager:restartKOReader()
        end,
    }))
end

-- Test-only handle on the file-local helpers (extractPlugin, parseVersion, isNewer,
-- composeBranchZipUrl). Not used by the plugin at runtime; exists so the busted
-- suite can unit-check them without a network or device.
Updater._test = {
    extractPlugin = extractPlugin,
    parseVersion = parseVersion,
    isNewer = isNewer,
    composeBranchZipUrl = composeBranchZipUrl,
}

return Updater
