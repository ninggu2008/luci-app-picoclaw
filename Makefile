# SPDX-License-Identifier: Apache-2.0
#
# OpenWrt package makefile for luci-app-picoclaw
#
# Provides a LuCI web interface to manage picoclaw-webui:
#   - service status
#   - start / stop / restart actions
#   - autostart toggle (procd enable / disable)
#   - logs viewer
#   - safe JSON-RPC backend via rpcd ACL
#

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-picoclaw
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

PKG_MAINTAINER:=picoclaw maintainers <noreply@example.invalid>
PKG_LICENSE:=Apache-2.0

PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)-$(PKG_VERSION)

# Build deps - no compilation needed, pure Lua + shell.
PKG_BUILD_DEPENDS:=

# Runtime deps. Note: this package ships the placeholder launcher at
# /opt/picoclaw/picoclaw-launcher (see INSTALL.md for the real-picoclaw
# overlay procedure); we do NOT depend on an external `picoclaw-webui`
# package because that would break `make package/luci-app-picoclaw/compile`
# against a stock OpenWrt/ImmortalWRT buildroot.
LUCI_PKG_DEPENDS:= \
    +luci-base \
    +rpcd \
    +cgi-io

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

    All actions are exposed through the rpcd object `luci.picoclaw`
    and gated by `/usr/share/rpcd/acl.d/40-picoclaw.json`. The package
    does not introduce any user-supplied shell-execution endpoint.
endef

define Build/Configure
endef

define Package/luci-app-picoclaw/conffiles
    /etc/config/picoclaw
endef

define Package/luci-app-picoclaw/install
    # ----- LuCI Lua module path -----
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

    # ----- rpcd plugin (Lua backend) -----
    $(INSTALL_DIR) $(1)/usr/lib/rpcd
    $(INSTALL_DATA) \
        ./files/usr/lib/rpcd/luci.picoclaw \
        $(1)/usr/lib/rpcd/luci.picoclaw

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

define Package/luci-app-picoclaw/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || /etc/init.d/rpcd restart >/dev/null 2>&1
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