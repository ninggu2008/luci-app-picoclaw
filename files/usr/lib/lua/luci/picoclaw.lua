--[[
    luci.picoclaw - in-process backend for the LuCI picoclaw application.

    This module implements exactly the same primitives as the rpcd plugin
    /usr/share/rpcd/ucode/luci.picoclaw.uc:

        get_status()        -> { running, pid, port, autostart, uptime_s,
                                 version, launcher, log_path, service }
        get_logs(lines)     -> { lines = { ... }, path, total }
        set_action(action)  -> { ok, action, message }
        set_config(kv)      -> { ok, changed }

    The controller prefers the rpcd/ubus object when it is reachable and
    falls back to this module otherwise (rpcd not restarted after install,
    missing rpcd-mod-ucode, plugin failed to load, no Lua ubus binding on a
    minimal system, ...).  That fallback is what keeps the Status page from
    being stuck on "loading..." forever.

    Keep this file and the ucode plugin in sync - both must return the same
    reply shapes.

    SECURITY MODEL
    --------------
    1. set_action maps a literal whitelist onto
       `/etc/init.d/picoclaw-webui <action>`; no user supplied string ever
       reaches a shell unvalidated.
    2. set_config writes only to section picoclaw.webui and only the
       enumerated fields with bounded values.
    3. Every path handled here is a compile time constant; nothing user
       supplied is opened or executed.
--]]

local fs    = require "nixio.fs"
local nixio = require "nixio"
local uci   = require "luci.model.uci"
local sys   = require "luci.sys"

local M = { }

M.SERVICE  = "picoclaw-webui"
M.LAUNCHER = "/opt/picoclaw/picoclaw-launcher"
M.PIDFILE  = "/var/run/picoclaw-webui.pid"
M.LOG_PATH = "/var/log/picoclaw-webui.log"

local SERVICE  = M.SERVICE
local LAUNCHER = M.LAUNCHER
local PIDFILE  = M.PIDFILE
local LOG_PATH = M.LOG_PATH
local SYSLOG   = "/var/log/messages"
local RCD_DIR  = "/etc/rc.d"
local UCI_CFG  = "picoclaw"
local UCI_SEC  = "webui"

-- Read at most this many bytes from the end of a log file.
local LOG_TAIL_BYTES = 65536

M.ALLOWED_ACTIONS = {
	start   = true,
	stop    = true,
	restart = true,
	enable  = true,
	disable = true,
}

local ALLOWED_ACTIONS = M.ALLOWED_ACTIONS

local FIELD_VALIDATORS = {
	enabled = function(v)
		return v == "1" or v == "0" or v == "true" or v == "false"
	end,
	port = function(v)
		local n = tonumber(v)
		return n ~= nil and n >= 1 and n <= 65535
	end,
	log_alt = function(v)
		return v == "" or v == "syslog" or v == LOG_PATH
	end,
	verbosity = function(v)
		local n = tonumber(v)
		return n ~= nil and n >= 0 and n <= 3
	end,
}

-- ---------------------------------------------------------------------------
-- helpers
-- ---------------------------------------------------------------------------

-- Read a UCI option; returns `fallback` when unset, empty or unreadable.
local function uci_get(option, fallback)
	local ok, value = pcall(function()
		return uci.cursor():get(UCI_CFG, UCI_SEC, option)
	end)

	if ok and type(value) == "string" and value ~= "" then
		return value
	end

	return fallback
end

local function get_port()
	local n = tonumber(uci_get("port", "18800"))

	if n and n >= 1 and n <= 65535 then
		return math.floor(n)
	end

	return 18800
end

local function get_log_path()
	if uci_get("log_alt", "") == "syslog" then
		return SYSLOG
	end

	return LOG_PATH
end

-- ---------------------------------------------------------------------------
-- service state detection
--
-- The `pidfile` procd instance parameter only exists after the 24.10.x
-- releases (added 2026-03), so a pidfile written by procd cannot be relied
-- on.  The init script therefore writes the pid itself (it exec()s the
-- launcher through a tiny shell wrapper), and three independent signals are
-- combined here so that the Status page reports the true state even when
-- the service was started by hand:
--
--   1. the pidfile (validated against /proc),
--   2. a /proc scan for a process whose command line mentions the launcher,
--   3. the configured TCP port being in LISTEN state.
-- ---------------------------------------------------------------------------

local function proc_alive(pid)
	return fs.stat("/proc/" .. pid) ~= nil
end

local function pidfile_pid()
	local data = fs.readfile(PIDFILE)

	if not data then
		return nil
	end

	local pid = tonumber(data:match("^%s*(%d+)"))

	if pid and pid > 0 and proc_alive(pid) then
		return pid
	end

	return nil
end

local function proc_scan_pid()
	for path in fs.glob("/proc/[0-9]*") do
		local pid = tonumber(path:match("/(%d+)$"))

		if pid then
			local f = io.open("/proc/" .. pid .. "/cmdline", "rb")

			if f then
				local cmd = f:read(256) or ""
				f:close()

				if cmd:find(LAUNCHER, 1, true) then
					return pid
				end
			end
		end
	end

	return nil
end

-- Look for a listening socket on `port` in /proc/net/tcp{,6} (state 0A).
local function port_listening(port)
	local want = string.format("%04X", port)

	for _, path in ipairs({ "/proc/net/tcp", "/proc/net/tcp6" }) do
		local f = io.open(path, "r")

		if f then
			for line in f:lines() do
				local lport, state = line:match("^%s*%d+:%s*[0-9A-Fa-f]+:(%x+)%s+%S+%s+(%x+)")

				if lport and state == "0A" and lport:upper() == want then
					f:close()
					return true
				end
			end

			f:close()
		end
	end

	return false
end

local function service_state(port)
	local pid = pidfile_pid()

	if pid then
		return { running = true, pid = pid, source = "pidfile" }
	end

	pid = proc_scan_pid()

	if pid then
		return { running = true, pid = pid, source = "proc" }
	end

	if port_listening(port) then
		return { running = true, pid = nil, source = "port" }
	end

	return { running = false, pid = nil, source = "none" }
end

-- Autostart == the /etc/rc.d/S* symlink created by
-- `/etc/init.d/picoclaw-webui enable`.
local function autostart_enabled()
	for _ in fs.glob(RCD_DIR .. "/*picoclaw-webui") do
		return true
	end

	return false
end

-- Process uptime derived from /proc/<pid>/stat (starttime, field 22) and
-- the boot time in /proc/stat.
local function process_uptime(pid)
	local stat_buf = fs.readfile("/proc/" .. pid .. "/stat")
	local sys_buf  = fs.readfile("/proc/stat")

	if not stat_buf or not sys_buf then
		return nil
	end

	local btime  = sys_buf:match("btime%s+(%d+)")
	local fields = stat_buf:match("%)%s+(.*)$")

	if not btime or not fields then
		return nil
	end

	local tokens = { }
	for tok in fields:gmatch("%S+") do
		tokens[#tokens + 1] = tok
	end

	local starttime = tonumber(tokens[20])   -- 22nd field, 1 based

	if not starttime or starttime <= 0 then
		return nil
	end

	local up = os.time() - (tonumber(btime) + math.floor(starttime / 100))

	if up and up > 0 then
		return math.floor(up)
	end

	return nil
end

-- Purely informational: scan the launcher for a version banner.
local function launcher_version()
	local head = fs.readfile(LAUNCHER)

	if not head then
		return nil
	end

	local ver = head:match("[Pp]icoclaw[-_]?[Ll]auncher[^\n]*[Vv]ersion:%s*([%w%._%-]+)")
	         or head:match("VERSION=[\"']?([%w%._%-]+)")

	return ver
end

-- Split `data` into lines, keeping empty ones; a trailing newline does not
-- produce an extra empty element.
local function split_lines(data)
	local lines = { }

	for line in (data .. "\n"):gmatch("(.-)\n") do
		lines[#lines + 1] = line
	end

	if #lines > 0 and lines[#lines] == "" then
		table.remove(lines)
	end

	return lines
end

local function read_log_tail(path, max_lines)
	local out = { lines = { }, path = path, total = 0 }

	if not fs.access(path) then
		return out
	end

	local f = io.open(path, "rb")

	if not f then
		return out
	end

	local size = f:seek("end") or 0
	local from = (size > LOG_TAIL_BYTES) and (size - LOG_TAIL_BYTES) or 0

	f:seek("set", from)

	local data = f:read("*a") or ""
	f:close()

	local lines = split_lines(data)

	-- When we started reading mid file the first line is a fragment.
	if from > 0 and #lines > 0 then
		table.remove(lines, 1)
	end

	out.total = #lines

	if max_lines and #lines > max_lines then
		local tail = { }

		for i = #lines - max_lines + 1, #lines do
			tail[#tail + 1] = lines[i]
		end

		out.lines = tail
	else
		out.lines = lines
	end

	return out
end

-- ---------------------------------------------------------------------------
-- public API
-- ---------------------------------------------------------------------------

function M.get_status()
	local port = get_port()
	local state = service_state(port)

	local out = {
		running      = state.running,
		pid          = state.pid,
		port         = port,
		autostart    = autostart_enabled(),
		service      = SERVICE,
		launcher     = LAUNCHER,
		log_path     = get_log_path(),
		state_source = state.source,
	}

	if state.pid then
		local up = process_uptime(state.pid)

		if up then
			out.uptime_s = up
		end
	end

	local version = launcher_version()

	if version then
		out.version = version
	end

	return out
end

function M.get_logs(lines)
	lines = tonumber(lines) or 200

	if lines < 1 then
		lines = 1
	elseif lines > 2000 then
		lines = 2000
	end

	return read_log_tail(get_log_path(), math.floor(lines))
end

function M.set_action(action)
	if type(action) ~= "string" or not ALLOWED_ACTIONS[action] then
		return { ok = false, action = action, message = "unsupported action" }
	end

	-- Fail early (with a useful message) instead of letting procd enter a
	-- crash loop for a minute.
	if (action == "start" or action == "restart") and not fs.access(LAUNCHER, "x") then
		return {
			ok      = false,
			action  = action,
			message = "launcher missing or not executable: " .. LAUNCHER,
		}
	end

	-- `action` is drawn from the literal ALLOWED_ACTIONS table above; the
	-- only subprocess ever spawned is the fixed init script.
	local rc = 1

	local ok, status = pcall(sys.call, "/etc/init.d/" .. SERVICE .. " " .. action)

	if ok and status ~= nil then
		rc = math.floor(tonumber(status) or 1)
	end

	if rc ~= 0 then
		return { ok = false, action = action, message = "exit " .. tostring(rc) }
	end

	-- `start` / `restart`: confirm that the instance really stays up.  procd
	-- (and therefore the init script) also reports success when the launcher
	-- exits immediately - e.g. a launcher that daemonizes or a broken
	-- placeholder - which used to look like "the button does nothing".
	if action == "start" or action == "restart" then
		local port = get_port()

		for _ = 1, 8 do
			if service_state(port).running then
				return { ok = true, action = action, message = "ok" }
			end

			nixio.nanosleep(0, 250000000)   -- 250 ms
		end

		return {
			ok      = false,
			action  = action,
			message = "started but not running (see " .. LOG_PATH .. " and logread)",
		}
	end

	-- `enable` / `disable` are synchronous, so the rc.d symlink must match.
	if action == "enable" or action == "disable" then
		if autostart_enabled() ~= (action == "enable") then
			return { ok = false, action = action, message = "autostart flag not applied" }
		end
	end

	return { ok = true, action = action, message = "ok" }
end

function M.set_config(kv)
	if type(kv) ~= "table" then
		return { ok = false, message = "expected table" }
	end

	local ok, cursor = pcall(uci.cursor)

	if not ok or not cursor then
		return { ok = false, message = "cannot open uci context" }
	end

	local changed = { }

	for k, v in pairs(kv) do
		local validate = FIELD_VALIDATORS[k]

		if not validate then
			return { ok = false, message = "unknown field: " .. tostring(k) }
		end

		if type(v) ~= "string" and type(v) ~= "number" then
			return { ok = false, message = "invalid value for " .. tostring(k) }
		end

		v = tostring(v)

		if not validate(v) then
			return { ok = false, message = "invalid value for " .. tostring(k) }
		end

		local stored

		if k == "enabled" then
			stored = (v == "1" or v == "true") and "1" or "0"
		elseif k == "port" or k == "verbosity" then
			stored = tostring(math.floor(tonumber(v)))
		else
			stored = v
		end

		cursor:set(UCI_CFG, UCI_SEC, k, stored)
		changed[#changed + 1] = k
	end

	local committed = pcall(function() cursor:commit(UCI_CFG) end)

	if not committed then
		return { ok = false, message = "commit failed" }
	end

	return { ok = true, changed = changed }
end

return M
