# Installation

This document covers building, installing and verifying the
`luci-app-picoclaw` package on ImmortalWRT / OpenWrt.

## 1. Build (from source)

Prerequisites: a working OpenWrt / ImmortalWRT SDK or buildroot with the
standard `feeds` setup.

```sh
# inside the OpenWrt buildroot
mkdir -p package/luci
cp -R /path/to/luci-app-picoclaw package/luci/luci-app-picoclaw

# add to feeds (optional, only if you're publishing through feeds.conf)
# echo 'src-git luci ...' >> feeds.conf
./scripts/feeds update luci
./scripts/feeds install -a -p luci

make menuconfig
#   LuCI  ---> 3. Applications  ---> <M> luci-app-picoclaw
make package/luci-app-picoclaw/compile V=s -j$(nproc)
```

The resulting `.ipk` lives in
`bin/packages/<target-arch>/luci/luci-app-picoclaw_*.ipk`.

## 2. Install on the router

### 2.1 Via `opkg`

```sh
scp bin/packages/*/luci/luci-app-picoclaw_*.ipk root@router:/tmp/
ssh root@router
opkg update
opkg install /tmp/luci-app-picoclaw_*.ipk
/etc/init.d/rpcd restart
```

### 2.2 From local source (no SDK)

Drop the `files/` tree into the router filesystem:

```sh
scp -r files/* root@router:/
ssh root@router
chmod +x /etc/init.d/picoclaw-webui /opt/picoclaw/picoclaw-launcher
/etc/init.d/rpcd restart
```

After install, `Services -> picoclaw` should appear in LuCI.

## 3. Verification

### 3.1 Files

```sh
ls /usr/lib/lua/luci/controller/picoclaw.lua
ls /usr/lib/lua/luci/model/cbi/picoclaw_config.lua
ls /usr/lib/lua/luci/view/picoclaw/status.htm
ls /usr/lib/lua/luci/view/picoclaw/logs.htm
ls /usr/lib/rpcd/luci.picoclaw
ls /usr/share/rpcd/acl.d/40-picoclaw.json
ls /etc/init.d/picoclaw-webui
ls /etc/config/picoclaw
ls -l /opt/picoclaw/picoclaw-launcher
```

### 3.2 rpcd

```sh
ubus -S list | grep picoclaw
# expected:
#   luci.picoclaw

ubus -S call luci.picoclaw get_status '{"lines":1}'
ubus -S call luci.picoclaw get_logs '{"lines":20}'
ubus -S call luci.picoclaw set_action '{"action":"start"}'
```

If `ubus call` returns `permission denied`, the ACL was not reloaded.
Run `/etc/init.d/rpcd restart` again.

### 3.3 Service

```sh
/etc/init.d/picoclaw-webui status
/etc/init.d/picoclaw-webui enabled
/etc/init.d/picoclaw-webui start
ss -tlnp | grep 18800
curl http://127.0.0.1:18800/   # placeholder text if no real launcher
```

### 3.4 LuCI

1. Log in to LuCI as root.
2. Open **Services -> picoclaw -> Status**.
3. Click **Start**, **Stop**, **Restart** — the table should reflect
   the new state within 5 s.
4. Toggle **Enable at boot** / **Disable at boot** — the autostart
   badge should flip.

## 4. Uninstall

```sh
opkg remove luci-app-picoclaw
/etc/init.d/picoclaw-webui disable
/etc/init.d/picoclaw-webui stop
```

## 5. Real launcher overlay

The package ships a *placeholder* launcher at
`/opt/picoclaw/picoclaw-launcher`. To replace it with the real
picoclaw launcher (provided by the `picoclaw-webui` package or your own
script), drop the file into place with the same path and ensure it is
executable:

```sh
chmod +x /opt/picoclaw/picoclaw-launcher
/etc/init.d/picoclaw-webui restart
```

The real launcher must respect the following env vars set by the init
script:

| Variable             | Meaning                                |
| -------------------- | -------------------------------------- |
| `PICOCLAW_PORT`      | TCP port to bind (1..65535)             |
| `PICOCLAW_VERBOSITY` | 0..3                                   |
| `PICOCLAW_CONFIG`    | path to UCI config (`/etc/config/picoclaw`) |
| `PICOCLAW_LOGFILE`   | log file path                          |

It must also run as a **foreground** process — procd manages its
lifetime and respawns it on exit.