--[[
    luci.model.cbi.picoclaw_config

    CBI form backing the "Configuration" page. Drives the @webui section
    of /etc/config/picoclaw. Field values are bounded server-side in the
    rpcd plugin (`ALLOWED_CONFIG_FIELDS`); the widget-side constraints
    here are documentation, not the security boundary.
--]]

-- In LuCI Master / ucode-bridge compat mode the dispatcher no longer
-- injects `_` (gettext) as a Lua global when the CBI model file is
-- loaded. We have to require it explicitly.
local i18n = require "luci.i18n"
local _ = i18n.translate or i18n.gettext or function(s) return s end

local m = Map("picoclaw", _("picoclaw"),
    _("WebUI configuration for picoclaw. Changes are applied immediately "
    .. "and the daemon is restarted; do not edit this section during a "
    .. "long-running operation unless you have first set autostart off."))

m.pageaction = false
m:chain("luci")

-- ---------------------------------------------------------------------------
-- Section: webui (typed section "webui" in /etc/config/picoclaw)
-- ---------------------------------------------------------------------------

s = m:section(TypedSection, "webui", _("WebUI"))
s.anonymous = true
s.addremove = false

-- Auto-start at boot / current state
o = s:option(Flag, "enabled", _("Enable"))
o.rmempty   = false
o.default   = "0"
o.description = _("Start the picoclaw-webui service at boot. "
    .. "When you save this page the service is restarted automatically.")

-- Listen port
o = s:option(Value, "port", _("Listen port"))
o.default     = "18800"
o.datatype    = "port"
o.rmempty     = false
o.description = _("TCP port the launcher binds. Must be 1..65535.")

-- Log destination
o = s:option(ListValue, "log_alt", _("Log destination"))
o.default     = ""
o:value("",       _("picoclaw-webui.log (default)"))
o:value("/var/log/picoclaw-webui.log", _("picoclaw-webui.log"))
o:value("syslog", _("Syslog"))
o.description = _("Where to read logs from when the user opens the Logs tab. "
    .. "Setting this to `syslog` mixes picoclaw output with other system logs.")

-- Verbosity
o = s:option(ListValue, "verbosity", _("Verbosity"))
o.default = "1"
o:value("0", _("Quiet"))
o:value("1", _("Normal"))
o:value("2", _("Verbose"))
o:value("3", _("Debug"))
o.description = _("Forwarded to the launcher as PICOCLAW_VERBOSITY (0..3).")

return m