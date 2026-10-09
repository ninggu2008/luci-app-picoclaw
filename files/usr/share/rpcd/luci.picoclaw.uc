// SPDX-License-Identifier: Apache-2.0
//
// luci.picoclaw - rpcd plugin (ucode version, for rpcd 2026.07.19+
// / ImmortalWRT 26.x snapshots). Loaded by rpcd-mod-ucode from
// /usr/share/rpcd/*.uc, replacing the legacy Lua loader at
// /usr/lib/rpcd/*.lua which was removed in this rpcd release.
//
// Exposes the same surface as the legacy Lua plugin (gated by
// /usr/share/rpcd/acl.d/40-picoclaw.json):
//
//     get_status()             -> { running, pid, port, autostart, uptime_s,
//                                   version, launcher, log_path, service }
//     get_logs(lines=200)      -> { lines = [...], path, total }
//     set_action("start"|...)  -> { ok, action, message }
//     set_config({k=v,...})    -> { ok, changed }
//
// SECURITY MODEL
// --------------
// 1. set_action never concatenates user input into a shell command;
//    the only subprocess invocation is
//    `/etc/init.d/picoclaw-webui <action>` where <action> is one of
//    five constants from ALLOWED_ACTIONS.
// 2. set_config writes only to /config/picoclaw, fields bounded to
//    enumerated types and value ranges via FIELD_VALIDATORS.
// 3. Every section is wrapped in try/catch and falls back to a safe
//    default so a single subsystem failure never takes the whole
//    status response down.

const SERVICE  = "picoclaw-webui";
const LAUNCHER = "/opt/picoclaw/picoclaw-launcher";
const LOG_PATH = "/var/log/picoclaw-webui.log";
const UCI_CFG  = "picoclaw";
const UCI_SEC  = "webui";

const ALLOWED_ACTIONS = {
    start:   true,
    stop:    true,
    restart: true,
    enable:  true,
    disable: true,
};

const FIELD_VALIDATORS = {
    enabled:   function(v) {
        return v == "1" || v == "0" || v == "true" || v == "false";
    },
    port:      function(v) {
        const n = +v;
        // `n == n` rejects NaN without pulling in a helper.
        return n == n && n >= 1 && n <= 65535;
    },
    log_alt:   function(v) {
        return v == "" || v == "syslog" || v == "/var/log/picoclaw-webui.log";
    },
    verbosity: function(v) {
        const n = +v;
        return n == n && n >= 0 && n <= 3;
    },
};

function read_port() {
    try {
        const c = uci.cursor();
        const p = c.get(UCI_CFG, UCI_SEC, "port");
        if (p != null) {
            const n = +p;
            if (n == n && n >= 1 && n <= 65535) return n;
        }
    } catch (e) { /* uci unavailable, fall through */ }
    return 18800;
}

return {
    "luci.picoclaw": {
        get_status: function() {
            const out = {
                running:   false,
                pid:       null,
                port:      read_port(),
                autostart: false,
                service:   SERVICE,
                launcher:  LAUNCHER,
                log_path:  LOG_PATH,
            };

            // procd service state via ubus. `service list {name=...}`
            // returns { "<name>" = { instances = { <inst> = { running,
            // pid, ... } } } }.
            try {
                const res = ubus.call("service", "list", { name: SERVICE });
                if (res && res[SERVICE] && res[SERVICE].instances) {
                    for (const k in res[SERVICE].instances) {
                        const inst = res[SERVICE].instances[k];
                        if (inst && inst.running) {
                            out.running = true;
                            out.pid = inst.pid;
                            break;
                        }
                    }
                }
            } catch (e) { /* ubus failed; running stays false */ }

            // autostart: /etc/rc.d/<service> symlink is exactly what
            // `/etc/init.d/<service> enabled` ultimately inspects, and
            // reading it does not need a shell.
            try {
                out.autostart = !!fs.access("/etc/rc.d/" + SERVICE);
            } catch (e) {
                out.autostart = false;
            }

            // uptime (best-effort, optional).
            if (out.pid) {
                try {
                    const stat      = fs.readfile("/proc/" + out.pid + "/stat");
                    const proc_stat = fs.readfile("/proc/stat");
                    if (stat && proc_stat) {
                        const btime_m  = proc_stat.match(/^btime\s+(\d+)/);
                        const fields_m = stat.match(/\)\s+(.*)$/);
                        if (btime_m && fields_m) {
                            const tokens    = fields_m[1].split(/\s+/);
                            const starttime = +tokens[19];
                            if (starttime) {
                                const clk_tck = 100; // safe default
                                const up = time() - (+btime_m[1] + starttime / clk_tck);
                                if (up > 0) out.uptime_s = Math.floor(up);
                            }
                        }
                    }
                } catch (e) { /* ignore */ }
            }

            // version banner (purely informational, no execution).
            try {
                const head = fs.readfile(LAUNCHER);
                if (head) {
                    const m1 = head.match(/[Pp]icoclaw[-_]?launcher[-_\s]*[Vv]ersion:\s*([\w.\-]+)/);
                    const m2 = head.match(/VERSION=["']*([\w.\-]+)/);
                    const m  = m1 || m2;
                    if (m) out.version = m[1];
                }
            } catch (e) { /* ignore */ }

            return out;
        },

        get_logs: function(lines) {
            lines = +lines || 200;
            if (lines < 1)    lines = 1;
            if (lines > 2000) lines = 2000;

            let alt = "";
            try {
                alt = uci.cursor().get(UCI_CFG, UCI_SEC, "log_alt") || "";
            } catch (e) { /* ignore */ }

            // Path restricted to a hard-coded set; UCI can only select
            // from the permitted values (see set_config validators).
            let path = LOG_PATH;
            if (alt == "syslog") {
                path = "/var/log/messages";
            } else if (alt == "/var/log/picoclaw-webui.log") {
                path = alt;
            } else if (alt != "") {
                path = LOG_PATH; // unknown alt: ignore
            }

            if (!fs.access(path)) {
                return { lines: [], path: path, total: 0 };
            }

            let content = "";
            try {
                content = fs.readfile(path) || "";
            } catch (e) {
                return { lines: [], path: path, total: 0 };
            }

            const all = content.split("\n");
            // Drop the trailing empty element caused by the final \n.
            if (all.length > 0 && all[all.length - 1] == "") all.pop();
            const total = all.length;
            const start = total > lines ? total - lines : 0;
            return { lines: all.slice(start), path: path, total: total };
        },

        set_action: function(action) {
            if (typeof action != "string") {
                return { ok: false, message: "action must be a string" };
            }
            if (!ALLOWED_ACTIONS[action]) {
                return {
                    ok: false,
                    message: "unsupported action; allowed: start | stop | restart | enable | disable",
                };
            }
            let rc = 1;
            try {
                rc = system("/etc/init.d/" + SERVICE + " " + action);
            } catch (e) {
                return { ok: false, message: "system() failed: " + e };
            }
            return {
                ok: rc == 0,
                action: action,
                message: rc == 0 ? "ok" : ("exit " + rc),
            };
        },

        set_config: function(kv) {
            if (type(kv) != "object") {
                return { ok: false, message: "expected object" };
            }
            let cursor;
            try {
                cursor = uci.cursor();
            } catch (e) {
                return { ok: false, message: "uci not available" };
            }
            const changed = [];
            for (const k in kv) {
                const validate = FIELD_VALIDATORS[k];
                if (!validate) {
                    return { ok: false, message: "unknown field: " + k };
                }
                const v = kv[k];
                if (!validate(v)) {
                    return { ok: false, message: "invalid value for " + k };
                }
                let stored;
                if (k == "enabled") {
                    stored = (v == "1" || v == "true") ? "1" : "0";
                } else if (k == "port" || k == "verbosity") {
                    stored = "" + (+v);
                } else {
                    stored = "" + v;
                }
                cursor.set(UCI_CFG, UCI_SEC, k, stored);
                changed.push(k);
            }
            try {
                cursor.commit(UCI_CFG);
            } catch (e) {
                return { ok: false, message: "uci commit failed: " + e };
            }
            return { ok: true, changed: changed };
        },
    },
};
