--[[
    luci.controller.picoclaw

    Registers the "Services -> picoclaw" menu tree and the JSON endpoints
    used by the status / logs pages.

    Backends (in this order):

      1. the rpcd ubus object `luci.picoclaw` (ACL gated, see
         /usr/share/rpcd/acl.d/40-picoclaw.json) - preferred;
      2. the in-process implementation `luci.picoclaw`
         (/usr/lib/lua/luci/picoclaw.lua) - used when rpcd is not
         reachable.

    The fallback exists because the web UI must not depend on rpcd being
    reloaded after installation or on the ucode plugin having loaded.  Both
    backends implement the same primitives and the same literal whitelists,
    so there is no `execute` / `eval` endpoint in either of them.
--]]

module("luci.controller.picoclaw", package.seeall)

local UBUS_OBJECT = "luci.picoclaw"

-- Never hard-require the in-process backend: if its Lua dependencies are
-- broken the rpcd/ubus path should still work (and vice versa).
local backend
do
    local ok, mod = pcall(require, "luci.picoclaw")

    if ok and type(mod) == "table" then
        backend = mod
    end
end

-- ----------------------------------------------------------------------
-- Menu
-- ----------------------------------------------------------------------

function index()
    -- Everything is registered below the `admin` menu, so LuCI only exposes
    -- it to authenticated users with admin access. `acl = true` is kept as a
    -- defensive marker; the ubus object itself is gated by
    -- /usr/share/rpcd/acl.d/40-picoclaw.json.
    --
    -- Parent entry: "Services" -> "picoclaw" (aliases to status).
    --
    -- `alias()` must be called with varargs: passing a single Lua table
    -- produces `path = { <table> }`, which later fails in dispatcher.lua
    -- with `invalid value (table) at index 1 in table for 'concat'`.
    local root = entry(
        {"admin", "services", "picoclaw"},
        alias("admin", "services", "picoclaw", "status"),
        _("picoclaw"), 50
    )
    root.acl = true

    entry(
        {"admin", "services", "picoclaw", "status"},
        template("picoclaw/status"),
        _("Status"),
        10
    ).acl = true

    entry(
        {"admin", "services", "picoclaw", "config"},
        -- No `autoapply`: with it, luci-compat's cbi/footer.htm suppresses
        -- the "Save & Apply" button.  The explicit two-step flow also lets
        -- the user review the values before the service is restarted.
        cbi("picoclaw_config"),
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

    entry({"admin", "services", "picoclaw", "call", "status"},
        call("rpc_status")).acl = true

    entry({"admin", "services", "picoclaw", "call", "action"},
        call("rpc_action")).acl = true

    entry({"admin", "services", "picoclaw", "call", "logs"},
        call("rpc_logs")).acl = true

    entry({"admin", "services", "picoclaw", "call", "config"},
        call("rpc_config")).acl = true
end

-- ----------------------------------------------------------------------
-- Helpers
-- ----------------------------------------------------------------------

-- Literal whitelist; duplicated in the in-process backend and in the ucode
-- plugin so that modifying one of them is not enough to run anything else.
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

-- Connect to ubusd through whichever Lua binding this system provides:
-- `luci.ubus` (LuCI) or the bare `ubus` module (libubus-lua).
local function ubus_connect()
    local names = { "luci.ubus", "ubus" }

    for _, name in ipairs(names) do
        local mod

        if pcall(function() mod = require(name) end) then
            if type(mod) == "table" and type(mod.connect) == "function" then
                local ok, conn = pcall(mod.connect)

                if ok and conn then
                    return conn
                end
            end
        end
    end

    return nil
end

-- Call the rpcd ubus object. Returns result[, error string].
local function call_ubus(method, params)
    local conn = ubus_connect()

    if not conn then
        return nil, "no ubus client module (luci.ubus/ubus) available"
    end

    local ok, res = pcall(conn.call, conn, UBUS_OBJECT, method, params or {})
    pcall(function() conn:close() end)

    if not ok then
        return nil, "ubus call failed: " .. tostring(res)
    end

    if res == nil then
        return nil, "object '" .. UBUS_OBJECT .. "' is not registered"
    end

    return res
end

-- Invoke `method` on the rpcd object, falling back to the in-process
-- implementation when rpcd is unusable.
-- Returns result[, error string, source, fallback_reason].
local function call_backend(method, params, local_fn)
    local res, err = call_ubus(method, params)

    if type(res) == "table" then
        return res, nil, "ubus"
    end

    local ok, local_res = pcall(local_fn)

    if ok and type(local_res) == "table" then
        return local_res, nil, "local", err
    end

    if not ok then
        err = (err or "backend unavailable") .. "; local backend failed: " .. tostring(local_res)
    end

    return nil, (err or "backend unavailable")
             .. " (check `ls -l /usr/share/rpcd/ucode/`, "
             .. "`ubus -v list | grep picoclaw` and `/etc/init.d/rpcd restart`)"
end

-- Parse the incoming body as JSON if Content-Type is application/json,
-- otherwise fall back to the standard form-urlencoded helpers.
local function read_request_table()
    local ctype = (luci.http.getenv("CONTENT_TYPE") or ""):lower()

    if ctype:find("application/json", 1, true) then
        local body = luci.http.content() or ""

        if body == "" then return {} end

        local ok, parsed = pcall(luci.jsonc.parse, body)

        if ok and type(parsed) == "table" then
            return parsed
        end

        return nil, "malformed JSON body"
    end

    return luci.http.formvalue() or {}
end

-- ----------------------------------------------------------------------
-- WebUI redirect
-- ----------------------------------------------------------------------

function action_open_webui()
    local uci = require "luci.model.uci".cursor()
    local port = tonumber(uci:get("picoclaw", "webui", "port")) or 18800

    -- Derive the destination host from the request's Host header; fall
    -- back to the loopback address when it is missing or malformed. Only
    -- host names / IPs are accepted, never a path or query string.
    local host = luci.http.getenv("HTTP_HOST") or ""
    host = host:gsub(":.*$", "")

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
    local res, err, src, why = call_backend("get_status", nil,
        function() return backend and backend.get_status() end)

    if not res then
        write_json({ ok = false, error = err or "status unavailable" }, 500)
        return
    end

    write_json({ ok = true, data = res, backend = src, backend_error = why })
end

function rpc_action()
    local body = read_request_table() or {}
    local action = body.action or ""

    if not ALLOWED_ACTIONS[action] then
        write_json({
            ok = false,
            error = "unknown or disallowed action: " .. tostring(action)
                    .. "; allowed: start | stop | restart | enable | disable",
        }, 400)
        return
    end

    local res, err, src, why = call_backend("set_action", { action = action },
        function() return backend and backend.set_action(action) end)

    if not res then
        write_json({ ok = false, error = err or "action failed" }, 500)
        return
    end

    write_json({ ok = true, data = res, backend = src, backend_error = why })
end

function rpc_logs()
    local body = read_request_table() or {}
    local lines = tonumber(body.lines) or 200

    if lines < 1 then lines = 1 end
    if lines > 2000 then lines = 2000 end

    local res, err, src, why = call_backend("get_logs", { lines = lines },
        function() return backend and backend.get_logs(lines) end)

    if not res then
        write_json({ ok = false, error = err or "logs unavailable" }, 500)
        return
    end

    write_json({ ok = true, data = res, backend = src, backend_error = why })
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

        local res, cerr, src, cwhy = call_backend("set_config", { kv = clean },
            function() return backend and backend.set_config(clean) end)

        if not res then
            write_json({ ok = false, error = cerr or "configuration rejected" }, 400)
            return
        end

        write_json({ ok = true, data = res, backend = src, backend_error = cwhy })
    else
        local res, err, src, why = call_backend("get_status", nil,
            function() return backend and backend.get_status() end)

        if not res then
            write_json({ ok = false, error = err or "status unavailable" }, 500)
            return
        end

        write_json({ ok = true, data = res, backend = src, backend_error = why })
    end
end
