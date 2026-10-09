--[[
    luci.controller.picoclaw

    Registers the "Services -> picoclaw" menu tree and JSON-RPC HTTP
    endpoints that proxy to the rpcd object `luci.picoclaw`.

    The JSON endpoints are thin wrappers around `ubus.call("luci.picoclaw",
    <method>, ...)` and exist solely so that browser-side AJAX can call
    rpcd without exposing arbitrary shell execution to LuCI users.

    Every endpoint validates its inputs against a small whitelist and
    returns a JSON object. There is NO `execute` / `eval` endpoint.
--]]

module("luci.controller.picoclaw", package.seeall)

-- ----------------------------------------------------------------------
-- Menu
-- ----------------------------------------------------------------------

function index()
    local has_config = nixio.fs.access("/etc/config/picoclaw")

    if not has_config then
        return
    end

    -- Parent entry: "Services" -> "picoclaw" (aliases to status).
    --
    -- Newer LuCI's `alias()` is implemented as `alias(path, ...) -> {
    -- type="alias", path = { path, ... } }`. Passing a single Lua table
    -- produces `path = { <table> }`, which later fails in dispatcher.lua
    -- with `invalid value (table) at index 1 in table for 'concat'`.
    -- Use varargs so the path flattens correctly.
    local root = entry(
        {"admin", "services", "picoclaw"},
        alias("admin", "services", "picoclaw", "status"),
        _("picoclaw"), 50
    ).acl = true

    entry(
        {"admin", "services", "picoclaw", "status"},
        template("picoclaw/status"),
        _("Status"),
        10
    ).acl = true

    entry(
        {"admin", "services", "picoclaw", "config"},
        cbi("picoclaw_config", {autoapply = true}),
        _("Configuration"),
        20
    ).acl = true

    entry(
        {"admin", "services", "picoclaw", "logs"},
        template("picoclaw/logs"),
        _("Logs"),
        30
    ).acl = true

    entry(
        {"admin", "services", "picoclaw", "webui"},
        call("action_open_webui"),
        _("Open WebUI"),
        90
    ).acl = true

    -- ------------------------------------------------------------------
    -- JSON-RPC endpoints (kept under /admin/services/picoclaw/call/* so
    -- they remain inside the LuCI admin ACL scope).
    -- ------------------------------------------------------------------

    entry(
        {"admin", "services", "picoclaw", "call", "status"},
        call("rpc_status")
    ).acl = true

    entry(
        {"admin", "services", "picoclaw", "call", "action"},
        call("rpc_action")
    ).acl = true

    entry(
        {"admin", "services", "picoclaw", "call", "logs"},
        call("rpc_logs")
    ).acl = true

    entry(
        {"admin", "services", "picoclaw", "call", "config"},
        call("rpc_config")
    ).acl = true
end

-- ----------------------------------------------------------------------
-- Helpers
-- ----------------------------------------------------------------------

local ALLOWED_ACTIONS = {
    start   = true,
    stop    = true,
    restart = true,
    enable  = true,
    disable = true,
}

local ALLOWED_CONFIG_FIELDS = {
    enabled   = true,
    port      = true,
    log_alt   = true,
    verbosity = true,
}

local function write_json(tbl, status)
    luci.http.prepare_content("application/json")
    if status then luci.http.status(status) end
    luci.http.write_json(tbl)
end

local function call_ubus(method, params)
    local ubus = require "luci.ubus"
    local conn = ubus.connect()
    if not conn then
        return nil, "ubus_unavailable"
    end
    local ok, res = pcall(conn.call, conn, "luci.picoclaw", method, params or {})
    conn:close()
    if not ok then
        return nil, tostring(res)
    end
    return res
end

-- Parse the incoming body as JSON if Content-Type is application/json,
-- otherwise fall back to the standard form-urlencoded helpers.
local function read_request_table()
    local ctype = (luci.http.getenv("CONTENT_TYPE") or ""):lower()
    if ctype:find("application/json", 1, true) then
        local body = luci.http.content() or ""
        if body == "" then return {} end
        local ok, parsed = pcall(luci.jsonc.parse, body)
        if ok and type(parsed) == "table" then return parsed end
        return nil
    end
    return luci.http.formvalue() or {}
end

-- ----------------------------------------------------------------------
-- WebUI redirect
-- ----------------------------------------------------------------------

function action_open_webui()
    local uci = require "luci.model.uci".cursor()
    local port = tonumber(uci:get("picoclaw", "webui", "port")) or 18800

    -- We derive the destination host from the request's Host header. If
    -- the header is missing / malformed we fall back to the loopback
    -- address. Sanitisation: we only accept a hostname/IP, never a path
    -- or query string.
    local host = luci.http.getenv("HTTP_HOST") or ""
    host = host:gsub(":.*$", "")     -- strip port
    if not host:match("^[%w%.%-]+$") then
        host = "127.0.0.1"
    end
    local scheme = (luci.http.getenv("HTTPS") == "on") and "https" or "http"
    luci.http.redirect(scheme .. "://" .. host .. ":" .. port .. "/")
end

-- ----------------------------------------------------------------------
-- JSON-RPC handlers
-- ----------------------------------------------------------------------

function rpc_status()
    local res, err = call_ubus("get_status")
    if not res then
        write_json({ ok = false, error = err or "ubus call failed" }, 500)
        return
    end
    write_json({ ok = true, data = res })
end

function rpc_action()
    local body, err = read_request_table()
    if not body then
        write_json({ ok = false, error = "bad request: " .. tostring(err) }, 400)
        return
    end
    local action = body.action or ""
    if not ALLOWED_ACTIONS[action] then
        write_json({
            ok = false,
            error = "unknown or disallowed action: " .. action
                    .. "; allowed: start | stop | restart | enable | disable",
        }, 400)
        return
    end
    local res, err2 = call_ubus("set_action", { action = action })
    if not res then
        write_json({ ok = false, error = err2 or "ubus call failed" }, 500)
        return
    end
    write_json({ ok = true, data = res })
end

function rpc_logs()
    local body = read_request_table() or {}
    local lines = tonumber(body.lines) or 200
    if lines < 1 then lines = 1 end
    if lines > 2000 then lines = 2000 end
    local res, err = call_ubus("get_logs", { lines = lines })
    if not res then
        write_json({ ok = false, error = err or "ubus call failed" }, 500)
        return
    end
    write_json({ ok = true, data = res })
end

function rpc_config()
    local method = (luci.http.getenv("REQUEST_METHOD") or "GET"):upper()
    if method == "POST" then
        local body, err = read_request_table()
        if not body then
            write_json({ ok = false, error = "bad request: " .. tostring(err) }, 400)
            return
        end
        -- Whitelist fields: drop anything not in ALLOWED_CONFIG_FIELDS.
        local clean = {}
        for k, v in pairs(body) do
            if ALLOWED_CONFIG_FIELDS[k] and type(v) == "string" then
                clean[k] = v
            end
        end
        local res, err2 = call_ubus("set_config", clean)
        if not res then
            write_json({ ok = false, error = err2 or "ubus call failed" }, 400)
            return
        end
        write_json({ ok = true, data = res })
    else
        local res, err = call_ubus("get_status")
        if not res then
            write_json({ ok = false, error = err or "ubus call failed" }, 500)
            return
        end
        write_json({ ok = true, data = res })
    end
end