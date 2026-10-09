# Installation

This document covers building, installing and verifying the
`luci-app-picoclaw` package on OpenWrt / ImmortalWRT (target: **24.10**).

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
```

The package `postinst` clears the LuCI index caches and reloads rpcd for
you. If you installed the package with `--force-*` options or copied the
files by hand, do it manually:

```sh
/etc/init.d/rpcd reload
rm -f /tmp/luci-indexcache.*
rm -rf /tmp/luci-modulecache/
```

### 2.2 From local source (no SDK)

Drop the `files/` tree into the router filesystem:

```sh
scp -r files/* root@router:/
ssh root@router
chmod +x /etc/init.d/picoclaw-webui /opt/picoclaw/picoclaw-launcher
/etc/init.d/rpcd reload
rm -f /tmp/luci-indexcache.*
rm -rf /tmp/luci-modulecache/
```

After install, `Services -> picoclaw` should appear in LuCI.

### 2.3 Runtime dependencies

The package depends on and requires:

| Package            | Provided by                        |
| ------------------ | ---------------------------------- |
| `luci-base`        | LuCI core                          |
| `luci-lua-runtime` | Lua dispatcher, templates, nixio   |
| `luci-compat`      | classic CBI (Configuration tab)     |
| `rpcd-mod-ucode`   | ucode rpcd plugins (ubus object)    |

`luci-lua-runtime` and `luci-compat` carry the Lua LuCI stack that used to
live in `luci-base` before 23.05.

## 3. Verification

### 3.1 Files

```sh
ls /usr/lib/lua/luci/picoclaw.lua
ls /usr/lib/lua/luci/controller/picoclaw.lua
ls /usr/lib/lua/luci/model/cbi/picoclaw_config.lua
ls /usr/lib/lua/luci/view/picoclaw/status.htm
ls /usr/lib/lua/luci/view/picoclaw/logs.htm
ls /usr/share/rpcd/ucode/luci.picoclaw.uc
ls /usr/share/rpcd/acl.d/40-picoclaw.json
ls /etc/init.d/picoclaw-webui
ls /etc/config/picoclaw
ls -l /opt/picoclaw/picoclaw-launcher
```

Note: there is intentionally **no** file in `/usr/lib/rpcd/` — rpcd treats
everything in that directory as a shared object, and only ucode scripts
below `/usr/share/rpcd/ucode/` can add ubus objects.

### 3.2 rpcd

```sh
ls -l /usr/lib/rpcd/ucode.so          # must exist (rpcd-mod-ucode)
ls -l /usr/share/rpcd/ucode/luci.picoclaw.uc
ubus -S list | grep picoclaw          # expected: luci.picoclaw
ubus -S call luci.picoclaw get_status
ubus -S call luci.picoclaw get_logs '{"lines":20}'
ubus -S call luci.picoclaw set_action '{"action":"start"}'
```

If the object is missing, check rpcd's log — a bad ucode plugin is
skipped with `Unable to compile ucode script ...` or
`Skipping registration of ucode script ...`:

```sh
logread | grep -i rpcd
/etc/init.d/rpcd reload
```

The web UI does not require this object: if it cannot be reached the
controller falls back to `/usr/lib/lua/luci/picoclaw.lua` and the Status
page keeps working.

### 3.3 Service

```sh
/etc/init.d/picoclaw-webui start
/etc/init.d/picoclaw-webui status
/etc/init.d/picoclaw-webui enabled          # checks the /etc/rc.d symlink
/etc/init.d/picoclaw-webui enable           # sets enabled=1 + creates the symlink
ss -tlnp | grep 18800
curl http://127.0.0.1:18800/   # placeholder text if no real launcher
```

`enabled` in `/etc/config/picoclaw` only controls *autostart at boot*: it
is kept in sync with the `/etc/rc.d/S99picoclaw-webui` symlink by
`enable` / `disable`. `start`, `stop` and `restart` always work, no matter
what the flag says.

#### How "running" is detected

procd only gained the `pidfile` instance parameter *after* the 24.10.x
releases (it landed in 2026-03), so the init script writes the pidfile
itself: the instance command is
`/bin/sh -c 'echo $$ > /var/run/picoclaw-webui.pid; exec /opt/picoclaw/picoclaw-launcher'`
and `exec` keeps the pid valid.

The Status page combines three signals, in this order, and reports which
one matched in `state_source` (hover the State badge):

| `state_source` | Signal |
| -------------- | ------ |
| `pidfile` | `/var/run/picoclaw-webui.pid` exists and `/proc/<pid>` is alive |
| `proc` | a process whose `/proc/<pid>/cmdline` mentions `/opt/picoclaw/picoclaw-launcher` |
| `port` | the configured TCP port is in LISTEN state in `/proc/net/tcp{,6}` |
| `none` | none of the above → reported as stopped |

This means the page also reports the correct state when the launcher was
started by hand (not through `/etc/init.d/`), or when it replaced itself
with another binary (the shipped placeholder `exec`s `uhttpd`).

### 3.4 LuCI

1. Log in to LuCI as root.
2. Open **Services -> picoclaw -> Status**.
3. Click **Start**, **Stop**, **Restart** — the table should reflect
   the new state within 5 s.
4. Toggle **Enable at boot** / **Disable at boot** — the autostart
   badge should flip.

### 3.5 Troubleshooting the Status page

Symptom: the Status tab stays on `loading…`.

```sh
# 1. is the object registered?
ubus -v list | grep picoclaw

# 2. what does rpcd say?
logread | grep -iE 'rpcd|ucode'

# 3. does the in-process backend work?
lua -e 'require("luci.picoclaw"); local s=require("luci.picoclaw").get_status(); print(s.running, s.pid, s.port)'
```

If (3) works but (1) does not, the page will still display correct data
(the controller falls back automatically); fix the plugin by reloading
rpcd. If (3) fails too, the Lua runtime dependencies from 2.3 are missing.

Symptom: the Status tab says `stopped` while the launcher is running.
Check the `state_source` shown when hovering the State badge, then:

```sh
cat /var/run/picoclaw-webui.pid      # written by the init script wrapper
ps w | grep -F /opt/picoclaw/picoclaw-launcher
netstat -ltn | grep 18800            # or: ss -ltn
```

If the pidfile is missing because the service was started by hand, that is
expected - the `/proc` scan or the port check should still report
`running`. If all three signals fail, the launcher neither keeps its
pid, nor shows the launcher path in its command line, nor listens on the
configured port; in that case check `/var/log/picoclaw-webui.log` and the
`PICOCLAW_*` environment variables from section 5.

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
