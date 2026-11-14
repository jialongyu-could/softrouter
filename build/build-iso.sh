#!/bin/bash
# 把 OpenWrt x86_64 磁盘镜像封装成可引导 ISO（BIOS / SeaBIOS）
# 原理：isolinux + memdisk 把整块磁盘镜像载入内存后启动
# 依赖：xorriso isolinux syslinux-common
# 用法：bash build-iso.sh /path/to/openwrt-...-combined.img.gz
set -euo pipefail

IMG_GZ="${1:-}"
if [ -z "$IMG_GZ" ] || [ ! -f "$IMG_GZ" ]; then
	echo "用法: $0 openwrt-x86-64-generic-squashfs-combined.img.gz"
	exit 1
fi

command -v xorriso >/dev/null || { echo "请先安装: apt install xorriso isolinux syslinux-common"; exit 1; }
[ -f /usr/lib/ISOLINUX/isolinux.bin ] || { echo "缺少 /usr/lib/ISOLINUX/isolinux.bin"; exit 1; }
MEMDISK=/usr/lib/syslinux/memdisk
[ -f "$MEMDISK" ] || MEMDISK=/usr/lib/syslinux/memdisk/memdisk
[ -f "$MEMDISK" ] || { echo "缺少 syslinux memdisk"; exit 1; }

IMG="${IMG_GZ%.gz}"
if [ ! -f "$IMG" ]; then
	echo "==> 解压镜像"
	gzip -dc "$IMG_GZ" > "$IMG"
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ISO_ROOT="$WORK/iso"
mkdir -p "$ISO_ROOT/boot/isolinux"

cp /usr/lib/ISOLINUX/isolinux.bin "$ISO_ROOT/boot/isolinux/"
cp /usr/lib/syslinux/modules/bios/ldlinux.c32 "$ISO_ROOT/boot/isolinux/" 2>/dev/null || true
cp "$MEMDISK" "$ISO_ROOT/boot/isolinux/memdisk"
cp "$IMG" "$ISO_ROOT/softrouter.img"

cat > "$ISO_ROOT/boot/isolinux/isolinux.cfg" <<'EOF'
DEFAULT softrouter
PROMPT 0
TIMEOUT 30

LABEL softrouter
	MENU LABEL LongOS (OpenWrt x86_64)
	KERNEL memdisk
	APPEND initrd=softrouter.img raw
EOF

OUT_ISO="${IMG_GZ%.img.gz}.iso"
echo "==> 生成 ISO: $OUT_ISO"
xorriso -as mkisofs \
	-o "$OUT_ISO" \
	-isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
	-b boot/isolinux/isolinux.bin \
	-c boot/isolinux/boot.cat \
	-no-emul-boot -boot-load-size 4 -boot-info-table \
	"$ISO_ROOT"

ls -lh "$OUT_ISO"
echo
echo "提示：此 ISO 依赖 SeaBIOS 传统启动，内存需大于镜像体积（建议 4GB）。"
echo "      UEFI 机器建议直接把 img 导入为磁盘（qm importdisk），无需 ISO。"
