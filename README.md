# luci-app-picoclaw

[![Build IPK](https://github.com/ninggu2008/luci-app-picoclaw/actions/workflows/build.yml/badge.svg)](https://github.com/ninggu2008/luci-app-picoclaw/actions/workflows/build.yml)

LuCI web interface for managing the `picoclaw-webui` service on
OpenWrt / ImmortalWRT (**24.10** is the primary target).  Provides status,
start/stop/restart, autostart toggle and a logs viewer for the launcher
living at `/opt/picoclaw/picoclaw-launcher` (port **18800** by default).

## Architecture

The browser talks to JSON endpoints in the LuCI controller.  The controller
uses two interchangeable backends with identical semantics:

1. the ubus object **`luci.picoclaw`**, provided by an rpcd **ucode** plugin
   (`/usr/share/rpcd/ucode/luci.picoclaw.uc`) and gated by
   `/usr/share/rpcd/acl.d/40-picoclaw.json` — used whenever ubus is
   reachable;
2. the in-process Lua backend `luci/picoclaw.lua`, used as a fallback when
   rpcd/the plugin is unavailable (not reloaded after install, missing
   `rpcd-mod-ucode`, no Lua ubus binding, ...).

Both only accept a literal action whitelist and a fixed set of bounded UCI
fields, so the fallback does not widen the attack surface.  See
`SECURITY.md`.

> rpcd has **no Lua plugin support** (it `dlopen()`s `/usr/lib/rpcd/*` and
> can only run ucode scripts from `/usr/share/rpcd/ucode/`), which is why
> the backend is shipped in both flavours.

## Layout

```
luci-app-picoclaw/
├── Makefile                              # OpenWrt package build
├── files/
│   ├── usr/
│   │   ├── lib/
│   │   │   └── lua/luci/
│   │   │       ├── picoclaw.lua                  # in-process backend
│   │   │       ├── controller/picoclaw.lua       # menu + JSON endpoints
│   │   │       ├── model/cbi/picoclaw_config.lua # CBI config form
│   │   │       └── view/picoclaw/
│   │   │           ├── status.htm                # live status page
│   │   │           └── logs.htm                  # logs viewer
│   │   └── share/rpcd/
│   │       ├── ucode/luci.picoclaw.uc            # rpcd ucode plugin
│   │       └── acl.d/40-picoclaw.json            # ACL whitelist
│   ├── etc/
│   │   ├── config/picoclaw                       # UCI defaults
│   │   └── init.d/picoclaw-webui                 # procd init script
│   └── opt/picoclaw/picoclaw-launcher            # placeholder launcher
└── po/
    └── zh-cn/picoclaw.po                         # zh-CN translations
```

## Features

| Tab           | Description                                                          |
| ------------- | -------------------------------------------------------------------- |
| Status        | Live state, PID, port, autostart, uptime, version, log path          |
| Configuration | UCI form for `enabled / port / log_alt / verbosity`                  |
| Logs          | Last N lines of `/var/log/picoclaw-webui.log`, optional auto-refresh |
| Open WebUI    | Redirect to the configured port on the same host                     |

**No arbitrary command execution is exposed** — see `SECURITY.md` for the
threat model.

## Runtime dependencies (OpenWrt 24.10)

| Package           | Why                                                        |
| ----------------- | ---------------------------------------------------------- |
| `luci-base`       | LuCI core (ucode runtime, menu, rpcd ACLs)                 |
| `luci-lua-runtime`| Lua dispatcher, template engine, `luci.model.uci`, nixio   |
| `luci-compat`     | classic CBI engine used by the Configuration tab            |
| `rpcd-mod-ucode`  | loads `/usr/share/rpcd/ucode/*.uc` (the `luci.picoclaw` object) |

The package `DEPENDS` line declares all of them.

## Build

### From source (in buildroot)

```sh
# from the OpenWrt / ImmortalWRT build root
cp -R luci-app-picoclaw package/luci-app-picoclaw

./scripts/feeds update -a
./scripts/feeds install luci-app-picoclaw

make menuconfig
# LuCI -> Applications -> luci-app-picoclaw   <M>

make package/luci-app-picoclaw/{clean,compile} V=s
ls bin/packages/<arch>/luci/luci-app-picoclaw_*.ipk
```

### Pre-built (from CI / Releases)

```sh
curl -L -o /tmp/luci-app-picoclaw.ipk \
    https://github.com/ninggu2008/luci-app-picoclaw/releases/latest/download/luci-app-picoclaw_1.0.0-4_all.ipk
opkg install /tmp/luci-app-picoclaw.ipk

# Or pick from the Actions workflow artifacts page:
#   https://github.com/ninggu2008/luci-app-picoclaw/actions/workflows/build.yml
```

The CI-built IPK ships a `postinst` that clears the LuCI index caches and
reloads rpcd, so the menu entry and the ubus object are available right
after installation.  When installing by hand (copying `files/*` onto the
router) run:

```sh
/etc/init.d/rpcd reload
rm -f /tmp/luci-indexcache.*
rm -rf /tmp/luci-modulecache/
```

## Quick start

```sh
# Start the service now (enabled is about autostart, not about start)
/etc/init.d/picoclaw-webui start

# Enable it at boot (also sets picoclaw.webui.enabled=1)
/etc/init.d/picoclaw-webui enable

# ... or use the LuCI UI:
#   Services -> picoclaw -> Status    (Start/Stop/Restart, Enable/Disable at boot)
#   Services -> picoclaw -> Configuration
```

Equivalent UCI edits:

```sh
uci set picoclaw.@webui[0].port='18800'
uci set picoclaw.@webui[0].enabled='1'
uci commit picoclaw
/etc/init.d/picoclaw-webui enable     # keeps the flag and the rc.d symlink in sync
```

The launcher exposes its version banner in
`/opt/picoclaw/picoclaw-launcher`; the placeholder shipped with this
package responds on TCP/18800 with a self-identifying page so the UI
"Open WebUI" link is functional out of the box. Replace
`/opt/picoclaw/picoclaw-launcher` with the real picoclaw launcher to
deploy the full feature set.

## License

Apache License 2.0. See `LICENSE`.
