#
# accel-ppp 的 OpenWrt 打包（随固件源码一起编译）
# 上游：https://github.com/accel-ppp/accel-ppp
# 说明：只编译用户态服务端，PPPoE 依赖内核 kmod-pppoe / kmod-pppox
#
include $(TOPDIR)/rules.mk

PKG_NAME:=accel-ppp
PKG_VERSION:=1.14.0
PKG_RELEASE:=1

PKG_SOURCE:=$(PKG_VERSION).tar.gz
PKG_SOURCE_URL:=https://github.com/accel-ppp/accel-ppp/archive/refs/tags/
# 首次构建请固定哈希：make package/accel-ppp/download V=s 后把 sha256 填入
PKG_HASH:=skip

PKG_LICENSE:=GPL-2.0
PKG_MAINTAINER:=SoftRouter

PKG_BUILD_PARALLEL:=1
PKG_BUILD_DEPENDS:=libpcre2

include $(INCLUDE_DIR)/package.mk
include $(INCLUDE_DIR)/cmake.mk

define Package/accel-ppp
  SECTION:=net
  CATEGORY:=Network
  DEPENDS:=+kmod-pppoe +kmod-pppox +libpcre2-8 +libopenssl +libpthread +librt +libatomic
  TITLE:=High performance PPPoE/PPTP/L2TP/SSTP/IPoE server
  URL:=https://accel-ppp.org
endef

define Package/accel-ppp/description
  accel-ppp 是高性能的 PPPoE/PPTP/L2TP/SSTP/IPoE 服务端，
  支持 IPv4/IPv6 双栈与 IPv6 前缀委派（PD），作为本固件的
  PPPoE 服务端核心，替代原生 rp-pppoe-server。
endef

define Package/accel-ppp/conffiles
/etc/accel-ppp.conf
/etc/accel-ppp/accel-ppp.conf
endef

CMAKE_OPTIONS += \
	-DCMAKE_BUILD_TYPE=Release \
	-DPCRE2=TRUE \
	-DBUILD_DRIVER=FALSE \
	-DRADIUS=FALSE \
	-DSHAPER=FALSE \
	-DLOG_PGSQL=FALSE \
	-DNETSNMP=FALSE \
	-DCMAKE_INSTALL_PREFIX=/usr

define Package/accel-ppp/install
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_DIR) $(1)/etc/accel-ppp
	$(INSTALL_BIN) $(PKG_INSTALL_DIR)/usr/sbin/accel-ppp $(1)/usr/sbin/
	[ -f $(PKG_INSTALL_DIR)/usr/sbin/accel-cmd ] && \
		$(INSTALL_BIN) $(PKG_INSTALL_DIR)/usr/sbin/accel-cmd $(1)/usr/sbin/ || true
	$(INSTALL_BIN) ./files/accel-ppp.init $(1)/etc/init.d/accel-ppp
	$(INSTALL_CONF) ./files/accel-ppp.conf $(1)/etc/accel-ppp/accel-ppp.conf
	$(INSTALL_CONF) ./files/accel-ppp.conf $(1)/etc/accel-ppp.conf
endef

$(eval $(call BuildPackage,accel-ppp))
