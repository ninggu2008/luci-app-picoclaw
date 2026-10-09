# luci-app-picoclaw

LuCI web interface for managing the `picoclaw-webui` service on
ImmortalWRT / OpenWrt. Provides status, start/stop/restart, autostart
toggle and a logs viewer for the launcher living at
`/opt/picoclaw/picoclaw-launcher` (port **18800** by default).

## Layout

```
luci-app-picoclaw/
├── Makefile                              # OpenWrt package build
├── files/
│   ├── usr/
│   │   ├── lib/
│   │   │   ├── lua/luci/
│   │   │   │   ├── controller/picoclaw.lua       # menu + JSON-RPC
│   │   │   │   ├── model/cbi/picoclaw_config.lua # CBI config form
│   │   │   │   └── view/picoclaw/
│   │   │   │       ├── status.htm                # live status page
│   │   │   │       └── logs.htm                  # logs viewer
│   │   │   └── rpcd/luci.picoclaw                # rpcd plugin (ubus object)
│   │   └── share/rpcd/acl.d/40-picoclaw.json     # ACL whitelist
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
| Open WebUI    | Redirect to the configured port on the same host                      |

All buttons are wired to JSON endpoints that call the ACL-restricted
rpcd object `luci.picoclaw`. **No arbitrary command execution is
exposed.** See `SECURITY.md` for the threat model.

## Build

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

## Install

```sh
# on the router
opkg update
opkg install luci-app-picoclaw_*.ipk
/etc/init.d/rpcd restart
```

## Quick start

```sh
uci set picoclaw.webui=section
uci set picoclaw.webui=cfg030f00 # or `uci set picoclaw.@webui[0].enabled=1` after first run
# Easier: open LuCI -> Services -> picoclaw -> Configuration, tick "Enable", Save.

# Or via CLI:
uci set picoclaw.@webui[0].enabled='1'
uci commit picoclaw
/etc/init.d/picoclaw-webui enable
/etc/init.d/picoclaw-webui start
```

The launcher exposes its version banner in
`/opt/picoclaw/picoclaw-launcher`; the placeholder shipped with this
package responds on TCP/18800 with a self-identifying page so the UI
"Open WebUI" link is functional out of the box. Replace
`/opt/picoclaw/picoclaw-launcher` with the real picoclaw launcher to
deploy the full feature set.

## License

Apache License 2.0. See `LICENSE`.