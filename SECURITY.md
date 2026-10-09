# Security

## Threat model

`luci-app-picoclaw` is a LuCI application. Anyone with the LuCI admin
password already has root-equivalent access on the router; this
package does not introduce a new authentication boundary. The goal
of the security design is to make the *new attack surface added by
this package* small and explicit, not to gate the existing
admin-equivalent threat.

In particular:

* The package does NOT introduce any user-supplied shell-execution
  endpoint.
* Every mutating operation maps a literal whitelist onto a fixed
  `/etc/init.d/picoclaw-webui <verb>` invocation or onto a bounded UCI
  write.
* The same primitives are available through the ACL-restricted ubus
  object `luci.picoclaw`, so non-LuCI frontends can be delegated
  access without giving them shell access.

## Trust boundary

```
                +------------------------+
   browser  <--> | LuCI session (cookie) | -- existing LuCI ACL
                +------------------------+
                         |
                         v
        +----------------------------------+
        | controller/picoclaw.lua (HTTP)   |
        | - validates action name          |
        | - serialises JSON                |
        +----------------------------------+
                 |                    |
   ubus available|                    | ubus unavailable
                 v                    v
 +----------------------------+  +-----------------------------+
 | /usr/share/rpcd/acl.d/     |  | luci/picoclaw.lua           |
 | 40-picoclaw.json allowlist |  | (in-process, root, same     |
 |        |                   |  |  whitelists)                |
 |        v                   |  +-----------------------------+
 | rpcd ucode plugin          |             |
 | /usr/share/rpcd/ucode/     |             |
 | luci.picoclaw.uc           |             |
 | - whitelist of strings     |             |
 | - no shell concatenation   |             |
 +----------------------------+             |
                 |                         |
                 +------------+------------+
                              |
                              v (the only subprocess ever spawned)
                 /etc/init.d/picoclaw-webui <verb>
                   verb in {start,stop,restart,enable,disable}
```

## Hardening points

### 1. ACL file

`/usr/share/rpcd/acl.d/40-picoclaw.json` is the only thing that grants
non-root users access to the ubus object. The file is shipped read-only
by the package; if it is removed or renamed the ubus object degrades to
`permission denied` for non-admin users and continues to work for root.

The file declares:

* `read`: `get_status`, `get_logs` (any authenticated LuCI user)
* `write`: `get_status`, `get_logs`, `set_action`, `set_config`
  (admin only)

There is no `*` wildcard in either scope, and the ACL is only relevant
for callers that go through rpcd with a session; local root callers
(e.g. the LuCI controller) are inside the same trust domain.

### 2. Controller JSON endpoints

* Only literal strings are matched against whitelists (`ALLOWED_ACTIONS`,
  `ALLOWED_CONFIG_FIELDS`). Anything else returns HTTP 400 without
  touching the backend.
* The action whitelist exists in all three places (controller, in-process
  backend, ucode plugin), so modifying one of them to forward an
  arbitrary string is not enough to execute it.
* `host` extraction from the `Host` header is restricted to
  `%w%.%-` characters before being used to construct a redirect URL.
  The fallback is `127.0.0.1`.
* The in-process fallback runs in the LuCI/uhttpd process, i.e. in the
  same trust domain as the controller itself. It exists so that the page
  keeps working when rpcd is not reloaded or the ucode plugin is
  unavailable; it does not widen the set of operations (same whitelist,
  same fixed init script path).

### 3. Backends (ucode plugin and Lua module)

Both implementations of `luci.picoclaw` (the ucode rpcd plugin and
`/usr/lib/lua/luci/picoclaw.lua`) share the same rules:

* No dynamic code loading, no `eval`, no user-controlled command string.
* `set_action` only ever runs `/etc/init.d/picoclaw-webui <action>` with
  `action` drawn from a literal whitelist
  (`start`, `stop`, `restart`, `enable`, `disable`).
* `set_config` writes only to section `picoclaw.webui`, only fields with
  a validator (`enabled`, `port`, `log_alt`, `verbosity`), and each value
  must pass that validator (port 1..65535, log path from a fixed set,
  ...). `log_alt` can never select an arbitrary file to read.
* `get_logs` reads from one of two compile-time constant paths
  (`/var/log/picoclaw-webui.log`, `/var/log/messages`).
* All filesystem paths are constants; nothing user supplied is opened.

### 4. Init script

* Action validation is delegated to rc.common, which only dispatches
  verbs it knows about (`start`, `stop`, `restart`, `reload`, `enable`,
  `disable`, `enabled`, `running`, `status`, `info`, `trace`, `boot`,
  `shutdown`); anything else prints the help text and does nothing.
  (A hand-rolled `case "$1"` in the init script cannot work: rc.common
  consumes the action argument before sourcing the script.)
* Reads UCI values through `uci_get`, which only queries the known config
  section.
* The procd instance command is the fixed literal
  `/bin/sh -c 'echo $$ > /var/run/picoclaw-webui.pid; exec <launcher>'`,
  where `<launcher>` is one of two compile-time constants
  (`/opt/picoclaw/picoclaw-launcher` if executable, otherwise the bundled
  `/usr/libexec/picoclaw-launcher-placeholder`).
  It is written by the init script itself (procd only learned the `pidfile`
  parameter after the 24.10.x releases); no UCI value is ever interpolated
  into it - the port and verbosity reach the launcher through `PICOCLAW_*`
  environment variables.
* `enable` / `disable` only touch `/etc/rc.d/S99picoclaw-webui` and the
  `picoclaw.webui.enabled` flag.

### 5. Template / JS

* All `script` blocks are `//<![CDATA[...]]>` and contain only DOM
  glue; no `eval`, no `new Function`, no string-built URLs from form
  values without prior validation.
* Server-provided strings are written through `textContent` (or escaped
  explicitly in the log viewer), never through `innerHTML`.

## Things this package does NOT protect against

* An attacker who has the LuCI admin password — they already own the
  router.
* A compromised `picoclaw-webui` binary — it runs as root inside
  procd.
* `rpcd` bugs that bypass the ACL.

For those, use defence-in-depth at the host level (filesystem
integrity monitoring, signed binaries, runtime confinement, …) rather
than asking the LuCI app to be safe.

## Reporting issues

Open a ticket in your distribution's bug tracker. Please do not file
issues about how an *already-powered* user can run arbitrary commands
on the router — that's by design and not within this package's threat
model.
