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
	OWN_SRC=1
else
	SRC=$(cd "$SRCDIR" && pwd)
fi
OWN_SRC=${OWN_SRC:-0}

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
# 必须整编（vmlinux + modules）：只编 modules 的话 modpost 拿不到 vmlinux.o，
# 所有 vmlinux 导出符号（register_pernet_subsys 之类）都会变成 undefined，整个 modpost 失败。
make -C "$SRC" ARCH=arm64 -j"$JOBS" >"$WORK/build.log" 2>&1 \
	|| { tail -n 40 "$WORK/build.log"; die "内核整编失败，日志 $WORK/build.log"; }
[ -f "$SRC/vmlinux" ] || die "整编完了却没有 vmlinux"
[ -f "$SRC/Module.symvers" ] || die "整编完了却没有 Module.symvers"

# 5) 编 modems 的 sprd_modem：音频栈要它的 SIPIC/AGCP 符号（kits 里的 Module.symvers 就是这么来的）
VMOD=$WORK/vendor-mod
rm -rf "$VMOD"
mkdir -p "$VMOD"
cp -r "$MU300"/upstream/modules/sprd_modem "$VMOD/sprd_modem"
# sprd_modem 的 Kbuild 用 -I../wcn_bsp/kinclude 引 mu300_compat.h，同级必须有 wcn_bsp
cp -r "$MU300"/upstream/modules/wcn_bsp "$VMOD/wcn_bsp"
make -C "$SRC" ARCH=arm64 M="$VMOD/sprd_modem" -j"$JOBS" modules >"$WORK/sprd_modem.log" 2>&1 \
	|| { tail -n 40 "$WORK/sprd_modem.log"; die "sprd_modem 编不过，日志 $WORK/sprd_modem.log"; }

# 6) 组 kit
KIT=$OUT_ROOT/kit-$KREL
rm -rf "$KIT"
mkdir -p "$KIT/ext"
# 自己下的源码树直接搬过去，省一半磁盘（runner 只有十几 G，整编一份就要 6~8G）
if [ "${OWN_SRC:-0}" = 1 ]; then mv "$SRC" "$KIT/build"; else cp -a "$SRC" "$KIT/build"; fi
# ext：模块栈编译时要的头文件与符号
mkdir -p "$KIT/ext/sprd_modem" "$KIT/ext/wcn_bsp" "$KIT/ext/dma" "$KIT/ext/sound"
cp -a "$MU300"/upstream/modules/sprd_modem/kinclude "$KIT/ext/sprd_modem/" 2>/dev/null || true
cp -a "$VMOD"/sprd_modem/Module.symvers "$KIT/ext/sprd_modem/Module.symvers" || die "sprd_modem 没产出 Module.symvers"
# sound/Kbuild 引的是 soc/soc-*.c、core/compress_offload.c、drivers/aloop.c，直接拿内核源码树补齐
for d in soc core drivers; do
	cp -a "$KIT/build/sound/$d" "$KIT/ext/sound/" || die "内核 sound/$d 拷不过去"
done
cp -a "$MU300"/upstream/modules/wcn_bsp/kinclude "$KIT/ext/wcn_bsp/" 2>/dev/null || true
cp -a "$KIT/build"/drivers/dma/virt-dma.c "$KIT/build"/drivers/dma/virt-dma.h \
      "$KIT/build"/include/linux/dmaengine.h "$KIT/ext/dma/" 2>/dev/null || true

printf 'KREL=%s\nCONFIG=%s\nAUDIO=%s\n' "$KREL" "$CONFIG_SHA" "$AUDIO_SHA" > "$KIT/KIT"
echo "== kit 好了: $KIT"
cat "$KIT/KIT"
