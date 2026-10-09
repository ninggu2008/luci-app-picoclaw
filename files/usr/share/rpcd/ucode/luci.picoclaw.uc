// SPDX-License-Identifier: Apache-2.0
//
// luci.picoclaw - rpcd plugin (ucode version, for rpcd 2026.07.19+).
// Loaded by rpcd-mod-ucode from /usr/share/rpcd/ucode/*.uc; the
// rpcd 2026.07.19 release removed the legacy /usr/lib/rpcd/*.lua
// loader.
//
// Plugin shape (from OpenWrt rpcd source, file
// rpcd/examples/ucode/example-plugin.uc):
//
//     return {
//         "<ubus-object>": {
//             "<method>": {
//                 args: { <arg-name>: <example-value> },   // optional
//                 call: function(request) {                // `request` is
//                                                         //  passed
//                                                         //  positionally
//                     return { ... };                      //  OR
//                     request.reply(value);                //  OR
//                     request.error(UBUS_STATUS_*);        //
//                 }
//             }
//         }
//     };
//
// `args` declares the expected ubus type per arg by example: the
// runtime type of the example value IS the type. E.g. `200` -> INT32,
// `""` -> STRING, `{}` -> TABLE. The actual value is ignored at
// call time, only its type is enforced.
//
// Methods exposed (gated by /usr/share/rpcd/acl.d/40-picoclaw.json):
//
//     get_status()                  -> { running, pid, port, autostart,
//                                        uptime_s, version, launcher,
//                                        log_path, service }
//     get_logs(lines = 200)         -> { lines = [...], path, total }
//     set_action(action = "start")  -> { ok, action, message }
//     set_config(kv = {})           -> { ok, changed }
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

// Best-effort load probe. rpcd-mod-ucode scans /usr/share/rpcd/ucode
// at startup; this line writes a file the moment our module is
// compiled so we can tell "never loaded" from "loaded but a
// method call failed". We use fs.writefile() rather than system()
// because rpcd-mod-ucode's ucode runtime only mounts fs/ubus/uci -
// a bare system() call would just hit `try` here and silently fail.
try {
    fs.writefile("/tmp/luci.picoclaw.loaded",
        "loaded at " + time() + " pid=" + (fs.stat("/proc/self") ? "?" : "?") + "\n");
} catch (e) {}

const SERVICE  = "picoclaw-webui";
const LAUNCHER = "/opt/picoclaw/picoclaw-launcher";
const LOG_PATH = "/var/log/picoclaw-webui.log";
const UCI_CFG  = "picoclaw";
const UCI_SEC  = "webui";

// UBUS_STATUS_* (from /usr/lib/rpcd/ucode.so).
const UBUS_STATUS_INVALID_ARGUMENT = 2;
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

                return out;
            },
        },

        get_logs: {
            // lines: example value `200` -> ubus declares INT32.
            args: {
                lines: 200,
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
                    return { lines: [], path: path, total: 0 };
                }

                let content = "";
                try {
                    content = fs.readfile(path) || "";
                } catch (e) {
                    return { lines: [], path: path, total: 0 };
                }

                const all = content.split("\n");
                if (all.length > 0 && all[all.length - 1] == "") all.pop();
                const total = all.length;
                const start = total > lines ? total - lines : 0;
                return { lines: all.slice(start), path: path, total: total };
            },
        },

        set_action: {
            // action: example value `""` -> ubus declares STRING.
            args: {
                action: "",
            },
            call: function(req) {
                const action = req.args.action;
                if (typeof action != "string" || !ALLOWED_ACTIONS[action]) {
                    return req.error(UBUS_STATUS_INVALID_ARGUMENT);
                }
                let rc = 1;
                try {
                    rc = system("/etc/init.d/" + SERVICE + " " + action);
                } catch (e) {
                    return req.error(UBUS_STATUS_UNKNOWN_ERROR);
                }
                return {
                    ok:      rc == 0,
                    action:  action,
                    message: rc == 0 ? "ok" : ("exit " + rc),
                };
            },
        },

        set_config: {
            // kv: example value `{}` -> ubus declares TABLE.
            args: {
                kv: {},
            },
            call: function(req) {
                const kv = req.args.kv;
                if (type(kv) != "object") {
                    return req.error(UBUS_STATUS_INVALID_ARGUMENT);
                }
                let cursor;
                try {
                    cursor = uci.cursor();
                } catch (e) {
                    return req.error(UBUS_STATUS_UNKNOWN_ERROR);
                }
                const changed = [];
                for (const k in kv) {
                    const validate = FIELD_VALIDATORS[k];
                    if (!validate) {
                        return req.error(UBUS_STATUS_INVALID_ARGUMENT);
                    }
                    const v = kv[k];
                    if (!validate(v)) {
                        return req.error(UBUS_STATUS_INVALID_ARGUMENT);
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
                    return req.error(UBUS_STATUS_UNKNOWN_ERROR);
                }
                return { ok: true, changed: changed };
            },
        },
    },
};
