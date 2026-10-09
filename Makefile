# SPDX-License-Identifier: Apache-2.0
#
# OpenWrt package makefile for luci-app-picoclaw
#
# Provides a LuCI web interface to manage picoclaw-webui:
#   - service status
#   - start / stop / restart actions
#   - autostart toggle (procd enable / disable)
#   - logs viewer
#   - safe JSON-RPC backend, gated by rpcd ACL
#

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-picoclaw
PKG_VERSION:=1.0.0
PKG_RELEASE:=5

PKG_MAINTAINER:=picoclaw maintainers <noreply@example.invalid>
PKG_LICENSE:=Apache-2.0

PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)-$(PKG_VERSION)

# Build deps - no compilation needed, pure Lua + ucode + shell.
PKG_BUILD_DEPENDS:=

# Runtime deps.
#
#   luci-lua-runtime  Lua dispatcher, template engine, luci.model.uci,
#                     luci.sys, luci.i18n, nixio, libubus-lua, jsonc.
#                     In OpenWrt 24.10 these moved out of luci-base.
#   luci-compat       classic CBI engine (Map/TypedSection/Flag/Value/
#                     ListValue + cbi view templates) used by the
#                     Configuration tab. Also in luci-compat on 24.10.
#   rpcd-mod-ucode    loads /usr/share/rpcd/ucode/*.uc and registers the
#                     `luci.picoclaw` ubus object. (luci-base already pulls
#                     it in, but the plugin is useless without it, so name
#                     the dependency explicitly.)
#
# NOTE: this package targets OpenWrt/ImmortalWRT 23.05 and later. On older
# releases the Lua runtime lives in luci-base and luci-lua-runtime does not
# exist; adapt LUCI_PKG_DEPENDS accordingly.
LUCI_PKG_DEPENDS:= \
    +luci-base \
    +luci-lua-runtime \
    +luci-compat \
    +rpcd \
    +rpcd-mod-ucode

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-picoclaw
    SECTION:=luci
    CATEGORY:=LuCI
    SUBMENU:=3. Applications
    TITLE:=LuCI support for picoclaw
    DEPENDS:=$(LUCI_PKG_DEPENDS)
    PKGARCH:=all
endef

define Package/luci-app-picoclaw/description
    LuCI application providing a web frontend for picoclaw-webui.

    Features:
      * Live service status (running / stopped, PID, port)
      * Start / Stop / Restart buttons
      * Autostart toggle (procd enable / disable)
      * Logs viewer with refresh
      * UCI-driven configuration (port, autostart)

    The UI uses the in-process backend /usr/lib/lua/luci/picoclaw.lua and
    prefers the ubus object `luci.picoclaw` whenever it is available. The
    object is provided by an rpcd ucode plugin and gated by
    /usr/share/rpcd/acl.d/40-picoclaw.json. Neither backend introduces a
    user-supplied shell-execution endpoint.
endef

define Build/Configure
endef

define Package/luci-app-picoclaw/conffiles
    /etc/config/picoclaw
endef

define Package/luci-app-picoclaw/install
    # ----- LuCI Lua modules -----
    $(INSTALL_DIR) $(1)/usr/lib/lua/luci
    $(INSTALL_DATA) \
        ./files/usr/lib/lua/luci/picoclaw.lua \
        $(1)/usr/lib/lua/luci/picoclaw.lua

    $(INSTALL_DIR) $(1)/usr/lib/lua/luci/controller
    $(INSTALL_DATA) \
        ./files/usr/lib/lua/luci/controller/picoclaw.lua \
        $(1)/usr/lib/lua/luci/controller/picoclaw.lua

    $(INSTALL_DIR) $(1)/usr/lib/lua/luci/model/cbi
    $(INSTALL_DATA) \
        ./files/usr/lib/lua/luci/model/cbi/picoclaw_config.lua \
        $(1)/usr/lib/lua/luci/model/cbi/picoclaw_config.lua

    $(INSTALL_DIR) $(1)/usr/lib/lua/luci/view/picoclaw
    $(INSTALL_DATA) \
        ./files/usr/lib/lua/luci/view/picoclaw/status.htm \
        $(1)/usr/lib/lua/luci/view/picoclaw/status.htm
    $(INSTALL_DATA) \
        ./files/usr/lib/lua/luci/view/picoclaw/logs.htm \
        $(1)/usr/lib/lua/luci/view/picoclaw/logs.htm

    # ----- rpcd plugin -----
    # rpcd >= 21.02 has no Lua plugin support: it dlopen()s shared objects
    # from /usr/lib/rpcd/ and spawns executables from /usr/libexec/rpcd/.
    # The only scripting interface is rpcd-mod-ucode, which scans
    # /usr/share/rpcd/ucode/ (RPC_UCSCRIPT_DIRECTORY in rpcd's ucode.c).
    $(INSTALL_DIR) $(1)/usr/share/rpcd/ucode
    $(INSTALL_DATA) \
        ./files/usr/share/rpcd/ucode/luci.picoclaw.uc \
        $(1)/usr/share/rpcd/ucode/luci.picoclaw.uc

    # ----- rpcd ACL -----
    $(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
    $(INSTALL_DATA) \
        ./files/usr/share/rpcd/acl.d/40-picoclaw.json \
        $(1)/usr/share/rpcd/acl.d/40-picoclaw.json

    # ----- /etc -----
    $(INSTALL_DIR) $(1)/etc/config
    $(INSTALL_DATA) \
        ./files/etc/config/picoclaw \
        $(1)/etc/config/picoclaw

    $(INSTALL_DIR) $(1)/etc/init.d
    $(INSTALL_BIN) \
        ./files/etc/init.d/picoclaw-webui \
        $(1)/etc/init.d/picoclaw-webui

    # ----- /opt/picoclaw/picoclaw-launcher (placeholder, see SECURITY.md) -----
    # The package ships a *test* launcher so the UI is fully functional
    # out of the box. Real picoclaw deployments are expected to overlay
    # this file via the picoclaw-webui package.
    $(INSTALL_DIR) $(1)/opt/picoclaw
    $(INSTALL_BIN) \
        ./files/opt/picoclaw/picoclaw-launcher \
        $(1)/opt/picoclaw/picoclaw-launcher
endef

# Drop the LuCI index caches (otherwise the new menu entry and views are
# not picked up until the next reboot) and reload rpcd so the ucode plugin
# is registered. rpcd re-executes itself on SIGHUP, which re-runs the
# plugin scan - a plain `restart` works as well.
define Package/luci-app-picoclaw/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
    rm -f /tmp/luci-indexcache.*
    rm -rf /tmp/luci-modulecache/
    /etc/init.d/rpcd reload >/dev/null 2>&1
}
exit 0
endef

define Package/luci-app-picoclaw/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
    /etc/init.d/picoclaw-webui stop >/dev/null 2>&1
    /etc/init.d/picoclaw-webui disable >/dev/null 2>&1
}
exit 0
endef

$(eval $(call BuildPackage,luci-app-picoclaw))
