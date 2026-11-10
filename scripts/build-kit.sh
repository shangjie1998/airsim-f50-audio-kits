#!/bin/bash
# 为一个内核 release 造一份构建套件（kit）：源码 + mu300-linux 补丁 + 设备配置 + 编好的 in-tree 模块符号。
#
#   scripts/build-kit.sh 6.18.54 [--mu300 <mu300-linux 目录>] [--jobs N] [--srcdir <已有的 linux 源码目录>]
#
# 产物：out/kit-<KREL>/
#   build/   内核构建树（含 Module.symvers、include/generated、已编好的 in-tree 模块）
#   ext/     sprd_modem / wcn_bsp 的头文件与符号、virt-dma 源码
#   KIT      KREL 与 CONFIG 校验行，build-modules.sh 会拿它核对
#
# 必须和设备的 .config 完全一致（config/<KREL>.config），否则编出来的 .ko 装上去内核会拒。
set -euo pipefail
TOP=$(cd "$(dirname "$0")/.." && pwd)
KREL=${1:?用法: scripts/build-kit.sh <KREL>}
shift
MU300=${MU300_DIR:-}
JOBS=${JOBS:-$(nproc)}
SRCDIR=${SRCDIR:-}
OUT_ROOT=${OUT_ROOT:-$TOP/out}

while [ $# -gt 0 ]; do
	case $1 in
		--mu300) MU300=$2; shift 2 ;;
		--jobs) JOBS=$2; shift 2 ;;
		--srcdir) SRCDIR=$2; shift 2 ;;
		*) echo "不认识参数 $1" >&2; exit 2 ;;
	esac
done

die() { echo "build-kit: $*" >&2; exit 1; }
line=$(awk -v k="$KREL" '$1 == k' "$TOP/kits.lock")
[ -n "$line" ] || die "kits.lock 里没有 $KREL"
set -- $line
SRC_SHA=$2 CONFIG_SHA=$3 MU300_REL=$4 AUDIO_SHA=$5

CFG=$TOP/config/$KREL.config
[ -f "$CFG" ] || die "缺 config/$KREL.config（从设备的 /proc/config.gz 导出来放这里）"
got=$(sha256sum "$CFG" | cut -d' ' -f1)
[ "$got" = "$CONFIG_SHA" ] || die "config/$KREL.config 的 sha256 是 $got，kits.lock 里写的是 $CONFIG_SHA"

SERIES=${KREL%.*}
SERIES=${SERIES%.*}
WORK=$OUT_ROOT/work-$KREL
mkdir -p "$WORK" "$OUT_ROOT"

# 1) 内核源码
if [ -z "$SRCDIR" ]; then
	SRC=$WORK/linux-$KREL
	if [ ! -d "$SRC" ]; then
		tarball=$WORK/linux-$KREL.tar.xz
		[ -f "$tarball" ] || curl -fL --retry 3 -o "$tarball" "https://cdn.kernel.org/pub/linux/kernel/v${SERIES%%.*}.x/linux-$KREL.tar.xz"
		got=$(sha256sum "$tarball" | cut -d' ' -f1)
		[ "$got" = "$SRC_SHA" ] || die "源码包 sha256 是 $got，kits.lock 里是 $SRC_SHA"
		tar -xf "$tarball" -C "$WORK"
	fi
else
	SRC=$(cd "$SRCDIR" && pwd)
fi

# 2) mu300-linux（补丁与 ext 头文件的来源）
if [ -z "$MU300" ]; then
	MU300=$WORK/mu300-linux
	if [ ! -d "$MU300" ]; then
		git clone -q --depth 1 --branch "$MU300_REL" https://github.com/dikeckaan/mu300-linux.git "$MU300" \
			|| die "拉不到 mu300-linux $MU300_REL"
	fi
fi

# 3) 打补丁（打不上就直接失败：静默跳过一个补丁，编出来的东西和发行版不一样）
for p in "$MU300"/upstream/patches/$SERIES/*.patch; do
	[ -f "$p" ] || continue
	patch -p1 -d "$SRC" --forward --silent <"$p" || die "补丁打不上: $(basename "$p")"
done

# 4) 配置 + 预编译
cp "$CFG" "$SRC/.config"
make -C "$SRC" ARCH=arm64 olddefconfig >/dev/null
rel=$(make -s -C "$SRC" ARCH=arm64 kernelrelease | tail -n 1)
[ "$rel" = "$KREL" ] || die "构建树自报 $rel，和 $KREL 不符"
make -C "$SRC" ARCH=arm64 -j"$JOBS" modules_prepare >/dev/null
make -C "$SRC" ARCH=arm64 -j"$JOBS" modules >"$WORK/modules.log" 2>&1 \
	|| { tail -n 30 "$WORK/modules.log"; die "in-tree modules 编不过，日志 $WORK/modules.log"; }

# 5) 组 kit
KIT=$OUT_ROOT/kit-$KREL
rm -rf "$KIT"
mkdir -p "$KIT/ext"
cp -a "$SRC" "$KIT/build"
# ext：模块栈编译时要的头文件与符号
mkdir -p "$KIT/ext/sprd_modem" "$KIT/ext/wcn_bsp" "$KIT/ext/dma" "$KIT/ext/sound"
cp -a "$MU300"/upstream/modules/sprd_modem/kinclude "$KIT/ext/sprd_modem/" 2>/dev/null || true
cp -a "$MU300"/upstream/modules/sprd_modem/Module.symvers "$KIT/ext/sprd_modem/" 2>/dev/null || true
cp -a "$MU300"/upstream/modules/wcn_bsp/kinclude "$KIT/ext/wcn_bsp/" 2>/dev/null || true
cp -a "$KIT/build"/drivers/dma/virt-dma.c "$KIT/build"/drivers/dma/virt-dma.h \
      "$KIT/build"/include/linux/dmaengine.h "$KIT/ext/dma/" 2>/dev/null || true

printf 'KREL=%s\nCONFIG=%s\nAUDIO=%s\n' "$KREL" "$CONFIG_SHA" "$AUDIO_SHA" > "$KIT/KIT"
echo "== kit 好了: $KIT"
cat "$KIT/KIT"
