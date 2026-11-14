#!/bin/bash
# 在 Linux 构建机（Debian 12/Ubuntu 22.04+）上编译 LongOS 固件
# 依赖：git make gcc g++ libncurses-dev zlib1g-dev gawk unzip file wget rsync python3
# 用法：
#   bash build-firmware.sh                # 默认 OpenWrt v24.10.4
#   OPENWRT_VERSION=v23.05.5 bash build-firmware.sh
#   JOBS=8 bash build-firmware.sh
set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK:-$HOME/longos-build}"
OPENWRT_VERSION="${OPENWRT_VERSION:-v24.10.4}"
OPENWRT_REPO="${OPENWRT_REPO:-https://github.com/openwrt/openwrt.git}"
JOBS="${JOBS:-$(nproc)}"
SRC="$WORK/src"
OUT="$SRC_DIR/out"

need() {
	command -v "$1" >/dev/null 2>&1 || { echo "缺少依赖: $1，请先安装构建依赖"; exit 1; }
}
for c in git make gcc g++ gawk unzip wget rsync; do need "$c"; done

mkdir -p "$WORK" "$OUT"

if [ ! -d "$SRC/.git" ]; then
	echo "==> 克隆 OpenWrt $OPENWRT_VERSION"
	git clone --depth 1 -b "$OPENWRT_VERSION" "$OPENWRT_REPO" "$SRC"
else
	echo "==> 复用已有源码: $SRC"
fi

cd "$SRC"

echo "==> 更新 feeds"
./scripts/feeds update -a
./scripts/feeds install -a

echo "==> 注入自定义 accel-ppp 软件包"
rm -rf package/accel-ppp
cp -a "$SRC_DIR/build/package/accel-ppp" package/accel-ppp

echo "==> 注入 LongOS overlay"
rm -rf files
cp -a "$SRC_DIR/overlay" files
# Windows 下拷贝会丢失执行位，这里统一修复
chmod 755 files/usr/lib/longos/lo.sh \
          files/usr/lib/longos/monitor.sh \
          files/usr/sbin/longos \
          files/etc/init.d/longos \
          files/etc/init.d/trea \
          files/etc/uci-defaults/90-longos \
          files/etc/accel-ppp/ip-up.sh \
          files/etc/accel-ppp/ip-down.sh

echo "==> 生成 .config"
cp -f "$SRC_DIR/build/config.seed" .config
make defconfig

# 确认 accel-ppp 被选中
if ! grep -q '^CONFIG_PACKAGE_accel-ppp=y' .config; then
	echo "!! accel-ppp 未被选入固件，请检查 package/accel-ppp/Makefile"
	exit 1
fi

echo "==> 下载源码包"
make download -j"$JOBS" || true

echo "==> 开始编译（首次约需较长时间）"
make -j"$JOBS" || make -j1 V=s

echo "==> 收集产物"
cp -f bin/targets/x86/64/*combined*.img.gz "$OUT"/ 2>/dev/null || true
cp -f bin/targets/x86/64/*combined*.img "$OUT"/ 2>/dev/null || true
ls -lh "$OUT" || true

echo
echo "完成。烧写/导入方式："
echo "  PVE:  gzip -d $OUT/openwrt-x86-64-generic-squashfs-combined.img.gz"
echo "        qm importdisk <vmid> <解压后的 img> local-lvm"
echo "  或执行 build-iso.sh 生成 ISO 后用 PVE 光驱启动"
