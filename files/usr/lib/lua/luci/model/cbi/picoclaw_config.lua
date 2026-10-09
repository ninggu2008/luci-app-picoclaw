--[[
    luci.model.cbi.picoclaw_config

    CBI form backing the "Configuration" page. Drives the @webui section of
    /etc/config/picoclaw. Field values are bounded server-side in the
    backend (see FIELD_VALIDATORS in luci/picoclaw.lua and in the ucode
    plugin); the widget-side constraints here are for the user's benefit,
    not the security boundary.

    Requires luci-compat (classic CBI: Map, TypedSection, Flag, Value,
    ListValue) - see the package dependencies.
--]]

-- In newer LuCI the dispatcher no longer injects `_` (gettext) as a Lua
-- global when a CBI model is loaded, so require it explicitly.
local i18n = require "luci.i18n"
local sys  = require "luci.sys"

local _ = i18n.translate or i18n.gettext or function(s) return s end

-- Autostart symlink created by `/etc/init.d/picoclaw-webui enable`
-- (START=99, STOP=10 in that script).
local RCD_LINK   = "/etc/rc.d/S99picoclaw-webui"
local RCD_LINKS  = RCD_LINK .. " /etc/rc.d/K10picoclaw-webui"
local LINK_TARGET = "../init.d/picoclaw-webui"

local m = Map("picoclaw", _("picoclaw"),
    _("WebUI configuration for picoclaw. Saving this page (Save & Apply) "
    .. "restarts the service; do not edit this section during a "
    .. "long-running operation unless you have first set autostart off."))

-- NOTE: do *not* set `m.pageaction = false` here.  luci-compat's
-- cbi/footer.htm only emits the Save / Save & Apply / Reset buttons when
-- pageaction is true (the dispatcher defaults it to true), so clearing it
-- leaves the Configuration page without any way to apply changes.

m:chain("luci")

-- ---------------------------------------------------------------------------
-- Section: webui (typed section "webui" in /etc/config/picoclaw)
-- ---------------------------------------------------------------------------

local s = m:section(TypedSection, "webui", _("WebUI"))
s.anonymous = true
s.addremove = false

-- Autostart at boot.  The authoritative state is the /etc/rc.d symlink (what
-- /etc/init.d/rcS evaluates), so create/remove it together with the UCI flag.
local o = s:option(Flag, "enabled", _("Enable"))
o.default   = "0"
o.rmempty   = false
o.description = _("Start the picoclaw-webui service at boot. "
    .. "When you save this page the service is restarted automatically.")
o.write = function(self, section, value)
    -- Do NOT call `/etc/init.d/picoclaw-webui enable|disable` from here:
    -- those verbs run `uci commit`, which clears the pending UCI delta
    -- during the CBI parse.  The "Save & Apply" flow applies that delta
    -- afterwards and would then report "There are no changes to apply".
    -- Touching the symlink directly is enough - the flag itself is written
    -- through the normal CBI path below.
    if tostring(value) == "1" then
        sys.call("ln -sf " .. LINK_TARGET .. " " .. RCD_LINK)
    else
        sys.call("rm -f " .. RCD_LINKS)
    end

    return self.map:set(section, self.alias or self.option, value)
end

-- Listen port
o = s:option(Value, "port", _("Listen port"))
o.default     = "18800"
o.datatype    = "port"
o.rmempty     = false
o.description = _("TCP port the launcher binds. Must be 1..65535.")

-- Log destination
o = s:option(ListValue, "log_alt", _("Log destination"))
o.default     = ""
o:value("", _("picoclaw-webui.log (default)"))
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
