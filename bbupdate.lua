local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
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
        table.insert(parts, tonumber(part) or 0)
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
    -- Fallback: curl (available on Android, desktop)
    local handle = io.popen(string.format("curl -sL -H 'User-Agent: KOReader-BookBuddy' %q", url))
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

function Updater.install(old_version, new_version)
    local DataStorage = require("datastorage")
    local lfs = require("libs/libkoreader-lfs")

    UIManager:show(InfoMessage:new({
        text = _("Downloading update..."),
        timeout = 1,
    }))

    UIManager:scheduleIn(0.1, function()
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

        -- Extract into the plugin directory (strip the zipball's root folder)
        local plugin_path = DataStorage:getDataDir() .. "/plugins/bookbuddy.koplugin"
        local ok, err = Device:unpackArchive(zip_path, plugin_path, true)
        pcall(os.remove, zip_path)

        if not ok then
            UIManager:show(InfoMessage:new({
                text = _("Installation failed: ") .. tostring(err),
                timeout = 5,
            }))
            return
        end

        -- Restart KOReader to load the new version
        UIManager:show(ConfirmBox:new({
            text = T(_("BookBuddy updated to v%1.\n\nRestart KOReader now?"), new_version),
            ok_text = _("Restart"),
            ok_callback = function()
                UIManager:restartKOReader()
            end,
        }))
    end)
end

return Updater
