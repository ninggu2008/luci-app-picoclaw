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
chmod +x /etc/init.d/picoclaw-webui /usr/libexec/picoclaw-launcher-placeholder
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
ls -l /usr/libexec/picoclaw-launcher-placeholder   # fallback (this package)
ls -l /opt/picoclaw/picoclaw-launcher              # real launcher (picoclaw-webui) - optional
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
`/bin/sh -c 'echo $$ > /var/run/picoclaw-webui.pid; exec <launcher>'`, where
`<launcher>` is `/opt/picoclaw/picoclaw-launcher` when it is executable and
`/usr/libexec/picoclaw-launcher-placeholder` otherwise
and `exec` keeps the pid valid.

The Status page combines three signals, in this order, and reports which
one matched in `state_source` (hover the State badge):

| `state_source` | Signal |
| -------------- | ------ |
| `pidfile` | `/var/run/picoclaw-webui.pid` exists and `/proc/<pid>` is alive |
| `proc` | a process whose `/proc/<pid>/cmdline` mentions either launcher path |
| `port` | the configured TCP port is in LISTEN state in `/proc/net/tcp{,6}` |
| `none` | none of the above → reported as stopped |

This means the page also reports the correct state when the launcher was
started by hand (not through `/etc/init.d/`), or when it replaced itself
with another binary (the bundled fallback `exec`s `uhttpd`).

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

Symptom: the WebUI is unreachable from the LAN ("connection refused") but
the Status tab says `running`.

```sh
netstat -ltnp | grep 18800
#   127.0.0.1:18800 => the launcher only listens on loopback: start it with
#                      `-public` (see the args option above)
#   nothing at all => the launcher does not serve HTTP at all
```

The Status page annotates the Port row accordingly: `18800 (not listening)`
or `18800 (loopback only, not reachable from the LAN)`.

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

Symptom: pressing Start or Restart flashes `started but not running (...)`.
The init script accepted the command but nothing is listening afterwards -
that is exactly what a launcher that exits immediately or daemonizes looks
like (see section 5):

```sh
logread | grep picoclaw-webui        # "in a crash loop" / launcher errors
tail -20 /var/log/picoclaw-webui.log
ps w | grep -F -e /opt/picoclaw/picoclaw-launcher -e /usr/libexec/picoclaw-launcher-placeholder
```

Note that `procd` restarts a crashing instance every 5 seconds for up to
5 attempts, which is why the launcher banner can appear several times in
the log within a minute.

## 4. Uninstall

```sh
opkg remove luci-app-picoclaw
/etc/init.d/picoclaw-webui disable
/etc/init.d/picoclaw-webui stop
```

## 5. Real launcher

The real launcher simply lives at `/opt/picoclaw/picoclaw-launcher`; this
LuCI package reserves that path for the `picoclaw-webui` package (or your
own script) and installs nothing there, so both packages can be installed
side by side without an opkg file conflict.

```sh
# install the real launcher
chmod +x /opt/picoclaw/picoclaw-launcher
/etc/init.d/picoclaw-webui restart

# the Status page then shows it in the Launcher row, without the
# "(placeholder launcher, not the real picoclaw)" hint
```

Until that file exists the init script runs the fallback shipped by this
package, `/usr/libexec/picoclaw-launcher-placeholder`, which serves a
self-identifying page on TCP/18800 so the "Open WebUI" button in the Status
page is functional right after installation.

### Launcher command line

`picoclaw-launcher` is started as (see `picoclaw-launcher -h`):

```
/bin/sh -c 'echo $$ > /var/run/picoclaw-webui.pid; shift; exec "$@"' sh \
    <pidfile> /opt/picoclaw/picoclaw-launcher \
    -port 18800 [-d] [-no-browser -public ...] [config.json]
```

| UCI option               | Launcher argument                        |
| ------------------------ | ---------------------------------------- |
| `picoclaw.webui.port`    | `-port <port>`                           |
| `picoclaw.webui.verbosity` | `-d` when 2 or 3 (debug), nothing for 0/1 |
| `picoclaw.webui.args`    | extra options, e.g. `-no-browser -public`, `-d`, `-lang zh`, `-host <addr>`, `-console`; flags are inserted before the config path |
| `picoclaw.webui.config_file` | positional `config.json` argument (last); empty = launcher default `~/.picoclaw/config.json` |

All flags precede the positional config argument, because Go's flag parser
stops at the first non-flag argument.  Each option is passed as its own
`argv` word; nothing goes through a shell, so no value can be interpreted by
one.

The instance also gets these environment variables, which are **this
package's convention** - `picoclaw-launcher` itself ignores them, the bundled
fallback reads them, and other launchers may honour them:

| Variable             | Meaning                                |
| -------------------- | -------------------------------------- |
| `HOME`               | `/root` (picoclaw resolves `~/.picoclaw/config.json`) |
| `PICOCLAW_PORT`      | configured port                        |
| `PICOCLAW_VERBOSITY` | configured verbosity (0..3)             |
| `PICOCLAW_LOGFILE`   | log file path                          |
| `PICOCLAW_DOCROOT`   | docroot for the fallback's uhttpd       |

`PICOCLAW_CONFIG` is deliberately **not** exported: `picoclaw-launcher`
treats it as a JSON config path, and pointing it at the UCI file
`/etc/config/picoclaw` makes the WebUI fail with
`config.json syntax error ... invalid character 'c'`.  Use the positional
`config_file` option instead.

It must also run as a **foreground** process: procd supervises the pid it
started and treats any exit as a crash.  A launcher that forks into the
background (this is what `uhttpd` does without `-f`, and what the old
placeholder did) therefore makes procd restart it every
`respawn_timeout` (5 s) until it gives up:

```
logread | grep "in a crash loop"
```

The same happens when the launcher cannot start at all - for example the
placeholder's old `uhttpd -h /dev/null` invocation, which exited
immediately with `Error: Invalid directory /dev/null`.  The Status page
reports this as `started but not running (see ...)` when a Start/Restart
button is pressed, instead of pretending the action succeeded.
