#
# accel-ppp 的 OpenWrt 打包（随固件源码一起编译）
# 上游：https://github.com/accel-ppp/accel-ppp
# 说明：只编译用户态服务端，PPPoE 依赖内核 kmod-pppoe / kmod-pppox
#
include $(TOPDIR)/rules.mk

PKG_NAME:=accel-ppp
PKG_VERSION:=1.14.0
PKG_RELEASE:=6

PKG_SOURCE:=$(PKG_VERSION).tar.gz
PKG_SOURCE_URL:=https://github.com/accel-ppp/accel-ppp/archive/refs/tags/
# 首次构建请固定哈希：make package/accel-ppp/download V=s 后把 sha256 填入
PKG_HASH:=skip

PKG_LICENSE:=GPL-2.0
PKG_MAINTAINER:=LongOS

PKG_BUILD_PARALLEL:=1
PKG_BUILD_DEPENDS:=pcre2 libucontext

include $(INCLUDE_DIR)/package.mk
include $(INCLUDE_DIR)/cmake.mk

define Package/accel-ppp
  SECTION:=net
  CATEGORY:=Network
  DEPENDS:=+kmod-pppoe +kmod-pppox +libpcre2 +libucontext +libopenssl +libpthread +librt +libatomic
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

# 上游默认按 uname -m 推导 LIB_SUFFIX=64，会把 triton 库与模块装到
# /usr/lib64/accel-ppp，而 OpenWrt 根文件系统使用 /usr/lib。
# 显式置空 LIB_SUFFIX，安装路径与 RPATH 统一为 /usr/lib/accel-ppp。
CMAKE_OPTIONS += \
	-DCMAKE_BUILD_TYPE=Release \
	-DPCRE2=TRUE \
	-DLIB_SUFFIX= \
	-DBUILD_DRIVER=FALSE \
	-DRADIUS=FALSE \
	-DSHAPER=FALSE \
	-DLOG_PGSQL=FALSE \
	-DNETSNMP=FALSE \
	-DCMAKE_INSTALL_PREFIX=/usr

# accel-ppp 的 CMakeLists.txt 禁止源码内构建（in-source build），
# 但 OpenWrt 默认在 PKG_BUILD_DIR 内同时做源码解压与编译。
# 每次构建都会清理 build_dir，源码内构建无副作用，因此移除该检查。
define Build/Prepare
	$(call Build/Prepare/Default)
	sed -i '/CMAKE_BINARY_DIR STREQUAL CMAKE_HOME_DIRECTORY/,/endif[[:space:]]*()/d' \
		$(PKG_BUILD_DIR)/CMakeLists.txt
endef

define Package/accel-ppp/install
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_DIR) $(1)/etc/accel-ppp
	$(INSTALL_DIR) $(1)/usr/lib/accel-ppp
	$(INSTALL_BIN) $(PKG_INSTALL_DIR)/usr/sbin/accel-pppd $(1)/usr/sbin/accel-ppp
	[ -f $(PKG_INSTALL_DIR)/usr/sbin/accel-cmd ] && \
		$(INSTALL_BIN) $(PKG_INSTALL_DIR)/usr/sbin/accel-cmd $(1)/usr/sbin/ || true
	# 运行期模块（pppoe/ipoe/radius 等）与 libtriton.so 均由 accel-pppd 从
	# /usr/lib/accel-ppp 动态加载/链接，统一打入 accel-ppp 包内，
	# 避免拆分为独立 libtriton 包时跨包依赖无法被 defconfig 自动选中。
	$(INSTALL_BIN) $$(find $(PKG_INSTALL_DIR)/usr/lib/accel-ppp -maxdepth 1 -name '*.so') $(1)/usr/lib/accel-ppp/
	$(INSTALL_BIN) ./files/accel-ppp.init $(1)/etc/init.d/accel-ppp
	$(INSTALL_CONF) ./files/accel-ppp.conf $(1)/etc/accel-ppp/accel-ppp.conf
	$(INSTALL_CONF) ./files/accel-ppp.conf $(1)/etc/accel-ppp.conf
endef

$(eval $(call BuildPackage,accel-ppp))
