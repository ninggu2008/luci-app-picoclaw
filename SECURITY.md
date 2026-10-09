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
* All actions are routed through a single ubus object
  (`luci.picoclaw`) whose method list is fixed and ACL-restricted.
* The controller exposes only well-named JSON endpoints, each of
  which forwards to a single named ubus method with whitelisted
  arguments.

## Trust boundary

```
                +------------------------+
   browser  <--> | LuCI session (cookie) | -- existing LuCI ACL
                +------------------------+
                         |
                         v
        +----------------------------------+
        | controller/picoclaw.lua (HTTP)   |
        | - validates method/action name   |
        | - serialises JSON                |
        +----------------------------------+
                         |
                         v (ubus over unix socket)
        +----------------------------------+
        | /usr/share/rpcd/acl.d/40-picoclaw.json
        | allow-list of object+method      |
        +----------------------------------+
                         |
                         v
        +----------------------------------+
        | rpcd plugin /usr/lib/rpcd/luci.picoclaw
        | - whitelist of strings           |
        | - no shell concatenation         |
        +----------------------------------+
                         |
                         v (only this subprocess)
                /etc/init.d/picoclaw-webui <action>
                  action in {start,stop,restart,enable,disable}
```

## Hardening points

### 1. ACL file

`/usr/share/rpcd/acl.d/40-picoclaw.json` is the only thing that grants
non-root users access to the ubus object. The file is shipped read-only
by the package; if it is removed or renamed the page degrades to
`permission denied` for non-admin users and continues to work for root.

The file declares:

* `read`: `get_status`, `get_logs` (any authenticated LuCI user)
* `write`: `get_status`, `get_logs`, `set_action`, `set_config`
  (admin only)

There is no `*` wildcard in either scope. rpcd applies the ACL to every
ubus call regardless of the caller; the controller is therefore only a
convenience layer, not a security layer.

### 2. Controller JSON endpoints

* Only literal strings are matched against whitelists (`ALLOWED_ACTIONS`,
  `ALLOWED_RPC_METHODS`, `ALLOWED_CONFIG_FIELDS`). Anything else returns
  HTTP 400 without invoking ubus.
* The action whitelist is duplicated in the rpcd plugin, so even if the
  controller were modified to forward an arbitrary string, the rpcd
  plugin would still refuse it.
* `host` extraction from the `Host` header is restricted to
  `%w%.%-` characters before being used to construct a redirect URL.
  The fallback is `127.0.0.1`.

### 3. rpcd plugin

* No `loadstring`, no `dofile`, no `nixio.fs.execve`.
* `set_action` only ever runs `/etc/init.d/picoclaw-webui <action>`
  with `action` drawn from a Lua table literal.
* `set_config` writes only to `/config/picoclaw`, only fields in the
  `ALLOWED_CONFIG_FIELDS` table, and each value passes a per-field
  predicate (port 1..65535, log path from a fixed set, etc.).
* `get_logs` selects its read path from a fixed literal set; UCI
  cannot coerce an arbitrary file to be read.

### 4. Init script

* Refuses any argument outside the canonical procd verb set:
  `{start, stop, restart, reload, kill, status, running, enabled}`.
* Reads UCI values through `uci_get`, which only queries the known
  config section.

### 5. Template / JS

* All `script` blocks are `//<![CDATA[...]]>` and contain only DOM
  glue; no `eval`, no `new Function`, no string-built URLs from form
  values without prior validation.

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