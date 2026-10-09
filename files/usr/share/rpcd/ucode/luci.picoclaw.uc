// SPDX-License-Identifier: Apache-2.0
//
// luci.picoclaw - rpcd plugin (ucode version, for rpcd 2026.07.19+
// / ImmortalWRT 26.x snapshots). Loaded by rpcd-mod-ucode from
// /usr/share/rpcd/ucode/*.uc; the rpcd 2026.07.19 release removed
// the legacy /usr/lib/rpcd/*.lua loader.
//
// Plugin format (reverse-engineered from
// `strings /usr/lib/rpcd/ucode.so`):
//
//     return {
//         "<ubus-object>": {
//             "<method>": {
//                 args: { <arg-name>: "<type>" },  // optional
//                 call: function(req) {
//                     //   req.args.<arg>      parsed typed arg
//                     //   req.reply(value)    success path
//                     //   req.error(status)   UBUS_STATUS_* int
//                     //   req.defer()         async reply (unused)
//                 }
//             }
//         }
//     };
//
// Method callback receives a `request` object; the return value of
// the function is NOT used to send the reply - you must call
// `req.reply(...)` or `req.error(N)` explicitly.
//
// Methods exposed (gated by /usr/share/rpcd/acl.d/40-picoclaw.json):
//
//     get_status()                  -> { running, pid, port, autostart,
//                                        uptime_s, version, launcher,
//                                        log_path, service }
//     get_logs(lines = 200)         -> { lines = [...], path, total }
//     set_action(action = "...")    -> { ok, action, message }
//     set_config(kv = {...})        -> { ok, changed }
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

// UBUS_STATUS_* (from /usr/lib/rpcd/ucode.so).
const UBUS_STATUS_INVALID_ARGUMENT = 2;
const UBUS_STATUS_NOT_FOUND        = 4;
const UBUS_STATUS_UNKNOWN_ERROR    = 10;

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
    } catch (e) { }
    return 18800;
}

return {
    "luci.picoclaw": {
        get_status: {
            call: function(req) {
                const out = {
                    running:   false,
                    pid:       null,
                    port:      read_port(),
                    autostart: false,
                    service:   SERVICE,
                    launcher:  LAUNCHER,
                    log_path:  LOG_PATH,
                };

                // procd service state via ubus.
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
                } catch (e) { }

                // autostart: /etc/rc.d/<service> symlink.
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
                                    const clk_tck = 100;
                                    const up = time() - (+btime_m[1] + starttime / clk_tck);
                                    if (up > 0) out.uptime_s = Math.floor(up);
                                }
                            }
                        }
                    } catch (e) { }
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
                } catch (e) { }

                req.reply(out);
            },
        },

        get_logs: {
            args: {
                lines: "integer",
            },
            call: function(req) {
                let lines = req.args.lines;
                if (typeof lines != "number" || lines != lines) lines = 200;
                if (lines < 1)    lines = 1;
                if (lines > 2000) lines = 2000;

                let alt = "";
                try {
                    alt = uci.cursor().get(UCI_CFG, UCI_SEC, "log_alt") || "";
                } catch (e) { }

                // Path restricted to a hard-coded set; UCI can only
                // select from the permitted values (see set_config
                // validators).
                let path = LOG_PATH;
                if (alt == "syslog") {
                    path = "/var/log/messages";
                } else if (alt == "/var/log/picoclaw-webui.log") {
                    path = alt;
                } else if (alt != "") {
                    path = LOG_PATH; // unknown alt: ignore
                }

                if (!fs.access(path)) {
                    req.reply({ lines: [], path: path, total: 0 });
                    return;
                }

                let content = "";
                try {
                    content = fs.readfile(path) || "";
                } catch (e) {
                    req.reply({ lines: [], path: path, total: 0 });
                    return;
                }

                const all = content.split("\n");
                if (all.length > 0 && all[all.length - 1] == "") all.pop();
                const total = all.length;
                const start = total > lines ? total - lines : 0;
                req.reply({ lines: all.slice(start), path: path, total: total });
            },
        },

        set_action: {
            args: {
                action: "string",
            },
            call: function(req) {
                const action = req.args.action;
                if (typeof action != "string" || !ALLOWED_ACTIONS[action]) {
                    req.error(UBUS_STATUS_INVALID_ARGUMENT);
                    return;
                }
                let rc = 1;
                try {
                    rc = system("/etc/init.d/" + SERVICE + " " + action);
                } catch (e) {
                    req.error(UBUS_STATUS_UNKNOWN_ERROR);
                    return;
                }
                req.reply({
                    ok:      rc == 0,
                    action:  action,
                    message: rc == 0 ? "ok" : ("exit " + rc),
                });
            },
        },

        set_config: {
            args: {
                kv: "object",
            },
            call: function(req) {
                const kv = req.args.kv;
                if (type(kv) != "object") {
                    req.error(UBUS_STATUS_INVALID_ARGUMENT);
                    return;
                }
                let cursor;
                try {
                    cursor = uci.cursor();
                } catch (e) {
                    req.error(UBUS_STATUS_UNKNOWN_ERROR);
                    return;
                }
                const changed = [];
                for (const k in kv) {
                    const validate = FIELD_VALIDATORS[k];
                    if (!validate) {
                        req.error(UBUS_STATUS_INVALID_ARGUMENT);
                        return;
                    }
                    const v = kv[k];
                    if (!validate(v)) {
                        req.error(UBUS_STATUS_INVALID_ARGUMENT);
                        return;
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
                    req.error(UBUS_STATUS_UNKNOWN_ERROR);
                    return;
                }
                req.reply({ ok: true, changed: changed });
            },
        },
    },
};
