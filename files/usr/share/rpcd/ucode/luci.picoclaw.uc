// SPDX-License-Identifier: Apache-2.0
//
// luci.picoclaw - rpcd plugin (ucode flavour).
//
// rpcd >= 2021 loads every regular file below /usr/share/rpcd/ucode/ at
// startup (the loader lives in rpcd's ucode plugin, see rpcd's ucode.c,
// RPC_UCSCRIPT_DIRECTORY).  The file name may carry any extension; the
// object name comes from the returned signature object below.
//
// NOTE: rpcd does *not* support Lua plugins any more.  Anything placed in
// /usr/lib/rpcd/ is dlopen()ed as a shared object and executables in
// /usr/libexec/rpcd/ are spawned as helpers - a plain Lua file in
// /usr/lib/rpcd/ can never register an ubus object on OpenWrt 21.02+.
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
// The LuCI web UI talks to the in-process implementation
// (/usr/lib/lua/luci/picoclaw.lua) and only falls back to this object when
// ubus is reachable; both implementations must stay in sync.
//
// UCODE PORTABILITY RULES (rpcd runs whatever ucode version the platform
// ships - OpenWrt 24.10 pins ucode 3f64c808):
//   * there is no `typeof` operator, use type(value)
//   * there are no String methods, use the global match()/split() helpers
//   * there is no global Math object, use int() (or import from 'math')
//   * `for (x in ...)` needs `let`, not `const`
//   * fs/uci/ubus are separate modules and must be imported, they are NOT
//     globals in the rpcd ucode VM
//
// SECURITY MODEL
// --------------
// 1. set_action never concatenates user input into a shell command; the
//    only subprocess invocation is
//    `/etc/init.d/picoclaw-webui <action>` where <action> is one of five
//    constants from ALLOWED_ACTIONS.
// 2. set_config writes only to /etc/config/picoclaw, fields bounded to
//    enumerated types and value ranges via FIELD_VALIDATORS.
// 3. Every subsystem access is wrapped in try/catch and falls back to a
//    safe default so a single failure never takes the whole reply down.

'use strict';

import { access, lsdir, open, readfile, stat } from 'fs';
import { cursor } from 'uci';

const SERVICE     = 'picoclaw-webui';
const LAUNCHER    = '/opt/picoclaw/picoclaw-launcher';
const PLACEHOLDER = '/usr/libexec/picoclaw-launcher-placeholder';
const PIDFILE   = '/var/run/picoclaw-webui.pid';
const LOG_PATH  = '/var/log/picoclaw-webui.log';
const SYSLOG    = '/var/log/messages';
const RCD_DIR   = '/etc/rc.d';
const UCI_CFG   = 'picoclaw';
const UCI_SEC   = 'webui';

/* Read at most this many bytes from the end of a log file. */
const LOG_TAIL_BYTES = 65536;

const ALLOWED_ACTIONS = {
	start:   true,
	stop:    true,
	restart: true,
	enable:  true,
	disable: true,
};

const FIELD_VALIDATORS = {
	enabled:   (v) => (v == '1' || v == '0' || v == 'true' || v == 'false'),
	port:      (v) => { const n = +v; return n == n && n >= 1 && n <= 65535; },
	log_alt:   (v) => (v == '' || v == 'syslog' || v == LOG_PATH),
	verbosity: (v) => { const n = +v; return n == n && n >= 0 && n <= 3; },
};

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

/* Read a UCI option; returns `fallback` when unset, empty or unreadable. */
function read_opt(option, fallback) {
	try {
		const c = cursor();
		const v = c.get(UCI_CFG, UCI_SEC, option);

		if (v != null && v != '')
			return v;
	}
	catch (e) { }

	return fallback;
}

/* The launcher actually in use: the real one (owned by the picoclaw-webui
 * package) when it is executable, the fallback shipped by this package
 * otherwise.  Mirrors resolve_launcher() in /etc/init.d/picoclaw-webui. */
function resolve_launcher() {
	try {
		if (access(LAUNCHER, 'x'))
			return { path: LAUNCHER, placeholder: false };
	}
	catch (e) { }

	try {
		if (access(PLACEHOLDER, 'x'))
			return { path: PLACEHOLDER, placeholder: true };
	}
	catch (e) { }

	return null;
}

/* Fetch a named ubus call argument; rpcd always passes a dictionary as
 * request.args but be defensive so a malformed call cannot throw out of
 * the method. */
function get_arg(request, name) {
	try {
		const args = request ? request.args : null;

		if (type(args) == 'object')
			return args[name];
	}
	catch (e) { }

	return null;
}

function get_port() {
	const n = +read_opt('port', 18800);

	return (n == n && n >= 1 && n <= 65535) ? int(n) : 18800;
}

function get_log_path() {
	return (read_opt('log_alt', '') == 'syslog') ? SYSLOG : LOG_PATH;
}

/* Service state detection.
 *
 * The `pidfile` procd instance parameter only exists after the 24.10.x
 * releases (added 2026-03), so a pidfile written by procd cannot be relied
 * on.  The init script writes the pid itself (it exec()s the launcher
 * through a small shell wrapper) and three independent signals are combined
 * here so the Status page reports the real state even when the service was
 * started by hand:
 *
 *   1. the pidfile (validated against /proc),
 *   2. a /proc scan for a process whose command line mentions the launcher,
 *   3. the configured TCP port being in LISTEN state.
 */
function pidfile_pid() {
	try {
		const data = readfile(PIDFILE);
		const pid = data ? +trim(data) : NaN;

		if (pid > 0 && access('/proc/' + pid))
			return int(pid);
	}
	catch (e) { }

	return null;
}

function proc_scan_pid() {
	try {
		const entries = lsdir('/proc');

		for (let i = 0; i < length(entries); i++) {
			const pid = +entries[i];

			if (!(pid > 0))
				continue;

			try {
				const cmd = readfile('/proc/' + pid + '/cmdline');

				/* Either the real launcher or the bundled fallback
				 * counts as "the service is running". */
				if (cmd && (index(cmd, LAUNCHER) >= 0 || index(cmd, PLACEHOLDER) >= 0))
					return int(pid);
			}
			catch (e) { }
		}
	}
	catch (e) { }

	return null;
}

/* Look for a listening socket on `port` in /proc/net/tcp{,6} (state 0A). */
function port_listening(port) {
	const want = sprintf('%04X', port);
	const paths = [ '/proc/net/tcp', '/proc/net/tcp6' ];

	for (let i = 0; i < length(paths); i++) {
		try {
			const data = readfile(paths[i]);

			if (!data)
				continue;

			const lines = split(data, '\n');

			for (let j = 0; j < length(lines); j++) {
				const m = match(lines[j],
					/^[ \t]*[0-9]+:[ \t]*[0-9A-Fa-f]+:([0-9A-Fa-f]+)[ \t]+[^ \t]+[ \t]+([0-9A-Fa-f]+)/);

				if (m && m[2] == '0A' && uc(m[1]) == want)
					return true;
			}
		}
		catch (e) { }
	}

	return false;
}

function service_state(port) {
	let pid = pidfile_pid();

	if (pid != null)
		return { running: true, pid: pid, source: 'pidfile' };

	pid = proc_scan_pid();

	if (pid != null)
		return { running: true, pid: pid, source: 'proc' };

	if (port_listening(port))
		return { running: true, pid: null, source: 'port' };

	return { running: false, pid: null, source: 'none' };
}

/* Autostart == the /etc/rc.d/S* symlink created by `/etc/init.d/... enable`. */
function autostart_enabled() {
	try {
		const entries = lsdir(RCD_DIR);

		for (let i = 0; i < length(entries); i++) {
			const name = entries[i];

			if (match(name, /^[SK][0-9]*picoclaw-webui$/))
				return true;
		}
	}
	catch (e) { }

	return false;
}

/* Process uptime derived from /proc/<pid>/stat (starttime, field 22) and
 * the boot time in /proc/stat. */
function process_uptime(pid) {
	try {
		const stat_buf = readfile('/proc/' + pid + '/stat');
		const sys_buf  = readfile('/proc/stat');

		if (stat_buf && sys_buf) {
			const m_boot   = match(sys_buf, /btime\s+([0-9]+)/);
			const m_fields = match(stat_buf, /\)\s+(.*)$/);

			if (m_boot && m_fields) {
				const fields    = split(m_fields[1], /\s+/);
				const starttime = +fields[19];

				if (starttime > 0) {
					const up = time() - (+m_boot[1] + int(starttime / 100));

					if (up > 0)
						return int(up);
				}
			}
		}
	}
	catch (e) { }

	return null;
}

/* Purely informational: scan the launcher for a version banner. */
function launcher_version() {
	const launcher = resolve_launcher();

	if (launcher == null)
		return null;

	try {
		const head = readfile(launcher.path);

		if (head) {
			const m = match(head, /[Pp]icoclaw[-_]?[Ll]auncher[^\n]*[Vv]ersion:[ \t]*([A-Za-z0-9._-]+)/) ||
			          match(head, /VERSION=["']?([A-Za-z0-9._-]+)/);

			if (m)
				return m[1];
		}
	}
	catch (e) { }

	return null;
}

function read_log_tail(path, max_lines) {
	const result = { lines: [], path: path, total: 0 };

	try {
		if (!access(path))
			return result;

		let size = 0;

		try {
			const st = stat(path);

			if (st && st.size)
				size = st.size;
		}
		catch (e) { }

		const from  = (size > LOG_TAIL_BYTES) ? (size - LOG_TAIL_BYTES) : 0;
		const f     = open(path, 'r');

		if (!f)
			return result;

		let data = '';

		try {
			if (from > 0)
				f.seek(from, 0);

			data = f.read(LOG_TAIL_BYTES + 1) || '';
		}
		catch (e) {
			data = '';
		}

		try {
			f.close();
		}
		catch (e) { }

		const all = split(data, '\n');

		/* Drop the trailing empty element produced by a final newline. */
		if (length(all) > 0 && all[length(all) - 1] == '')
			pop(all);

		/* When we started reading mid-file the first line is a fragment. */
		if (from > 0 && length(all) > 0)
			shift(all);

		result.total = length(all);
		result.lines = (result.total > max_lines) ? slice(all, result.total - max_lines) : all;
	}
	catch (e) { }

	return result;
}

// ---------------------------------------------------------------------------
// methods
// ---------------------------------------------------------------------------

const methods = {
	get_status: {
		call: function() {
			const port     = get_port();
			const state    = service_state(port);
			const launcher = resolve_launcher();

			const out = {
				running:      state.running,
				pid:          state.pid,
				port:         port,
				autostart:    autostart_enabled(),
				service:      SERVICE,
				launcher:     launcher ? launcher.path : LAUNCHER,
				placeholder:  launcher ? launcher.placeholder : false,
				log_path:     get_log_path(),
				state_source: state.source,
			};

			if (state.pid != null) {
				const up = process_uptime(state.pid);

				if (up != null)
					out.uptime_s = up;
			}

			const version = launcher_version();

			if (version)
				out.version = version;

			return out;
		},
	},

	get_logs: {
		/* `lines: 200` declares the ubus argument as INT32. */
		args: {
			lines: 200,
		},

		call: function(request) {
			const arg   = get_arg(request, 'lines');
			let lines   = (type(arg) == 'int' || type(arg) == 'double') ? int(arg) : 200;

			if (lines < 1)
				lines = 1;
			else if (lines > 2000)
				lines = 2000;

			return read_log_tail(get_log_path(), lines);
		},
	},

	set_action: {
		/* `action: ""` declares the ubus argument as STRING. */
		args: {
			action: '',
		},

		call: function(request) {
			const action = get_arg(request, 'action');

			if (type(action) != 'string' || !ALLOWED_ACTIONS[action])
				return { ok: false, action: action, message: 'unsupported action' };

			/* Fail early (with a useful message) instead of letting procd
			 * enter a crash loop for a minute. */
			if ((action == 'start' || action == 'restart') && resolve_launcher() == null)
				return { ok: false, action: action,
				         message: 'no launcher found (' + LAUNCHER + ' or ' + PLACEHOLDER + ')' };

			let rc = 1;

			try {
				/* No timeout argument here: ucode's system(cmd, timeout)
				 * only wakes up when sigtimedwait() notices SIGCHLD, which
				 * is not reliable - passing e.g. 30000 blocks for the full
				 * 30 seconds even though the script finished at once.  The
				 * init script below only calls procd/uci helpers, so it
				 * cannot run longer than a moment. */
				rc = system('/etc/init.d/' + SERVICE + ' ' + action);
			}
			catch (e) {
				return { ok: false, action: action, message: 'invocation failed' };
			}

			if (rc != 0)
				return { ok: false, action: action, message: 'exit ' + rc };

			/* start / restart: confirm that the instance really stays up.
			 * The init script also returns 0 when the launcher exits
			 * immediately (daemonizing launchers, broken placeholders),
			 * which used to look like "the button does nothing". */
			if (action == 'start' || action == 'restart') {
				const port = get_port();

				for (let i = 0; i < 8; i++) {
					if (service_state(port).running)
						return { ok: true, action: action, message: 'ok' };

					sleep(250);   /* milliseconds */
				}

				return { ok: false, action: action,
				         message: 'started but not running (see ' + LOG_PATH + ' and logread)' };
			}

			/* enable / disable are synchronous, so the rc.d symlink must
			 * match the requested state. */
			if (action == 'enable' || action == 'disable') {
				if (autostart_enabled() != (action == 'enable'))
					return { ok: false, action: action, message: 'autostart flag not applied' };
			}

			return { ok: true, action: action, message: 'ok' };
		},
	},

	set_config: {
		/* `kv: {}` declares the ubus argument as TABLE. */
		args: {
			kv: {},
		},

		call: function(request) {
			const kv = get_arg(request, 'kv');

			if (type(kv) != 'object')
				return { ok: false, message: 'expected table' };

			let c;

			try {
				c = cursor();
			}
			catch (e) {
				return { ok: false, message: 'cannot open uci context' };
			}

			const changed = [];

			for (let key in kv) {
				const validate = FIELD_VALIDATORS[key];
				const value    = kv[key];

				if (!validate)
					return { ok: false, message: 'unknown field: ' + key };

				if (!validate(value))
					return { ok: false, message: 'invalid value for ' + key };

				let stored;

				if (key == 'enabled')
					stored = (value == '1' || value == 'true') ? '1' : '0';
				else if (key == 'port' || key == 'verbosity')
					stored = '' + int(+value);
				else
					stored = '' + value;

				c.set(UCI_CFG, UCI_SEC, key, stored);
				push(changed, key);
			}

			try {
				c.commit(UCI_CFG);
			}
			catch (e) {
				return { ok: false, message: 'commit failed' };
			}

			return { ok: true, changed: changed };
		},
	},
};

return { 'luci.picoclaw': methods };
