#!/bin/bash
# 拿 kit 编 25 个音频模块（口径照抄 mu300-audio 的 kernel/mainline/build-in.sh，不再走 docker）。
#
#   scripts/build-modules.sh 6.18.54 [--audio <mu300-audio 目录>] [--kit out/kit-6.18.54] [--tag <TAG>]
#
# 产物：out/modules-<KREL>/  25 个 .ko + KERNEL（KEY/KREL/CONFIG/TAG）
set -euo pipefail
TOP=$(cd "$(dirname "$0")/.." && pwd)
KREL=${1:?用法: scripts/build-modules.sh <KREL>}
shift
AUDIO=${AUDIO_DIR:-}
KIT=""
TAG=""
JOBS=${JOBS:-$(nproc)}
OUT_ROOT=${OUT_ROOT:-$TOP/out}

while [ $# -gt 0 ]; do
	case $1 in
		--audio) AUDIO=$2; shift 2 ;;
		--kit) KIT=$2; shift 2 ;;
		--tag) TAG=$2; shift 2 ;;
		--jobs) JOBS=$2; shift 2 ;;
		*) echo "不认识参数 $1" >&2; exit 2 ;;
	esac
done

die() { echo "build-modules: $*" >&2; exit 1; }
line=$(awk -v k="$KREL" '$1 == k' "$TOP/kits.lock")
[ -n "$line" ] || die "kits.lock 里没有 $KREL"
set -- $line
CONFIG_SHA=$3 AUDIO_SHA=$5
[ -n "$TAG" ] || TAG="kit-${KREL}"

[ -n "$KIT" ] || KIT=$OUT_ROOT/kit-$KREL
[ -d "$KIT/build" ] || die "没有 $KIT/build，先跑 scripts/build-kit.sh $KREL"
grep -qx "KREL=$KREL" "$KIT/KIT" || die "$KIT 不是 $KREL 的 kit"
grep -qx "CONFIG=$CONFIG_SHA" "$KIT/KIT" || die "$KIT 的 config 与 kits.lock 不符"
# 预检：这四样缺任何一个，后面都会以很难读的方式失败
for need in ext/sprd_modem/kinclude ext/sprd_modem/Module.symvers ext/sound/soc ext/sound/core ext/sound/drivers ext/dma/virt-dma.c; do
	[ -e "$KIT/$need" ] || die "kit 缺 $need（回看 scripts/build-kit.sh 的 ext 组装段）"
done

if [ -z "$AUDIO" ]; then
	AUDIO=$OUT_ROOT/work-$KREL/mu300-audio
	if [ ! -d "$AUDIO" ]; then
		git clone -q https://github.com/kai-wu-cortex/mu300-audio.git "$AUDIO" || die "拉不到 mu300-audio"
		git -C "$AUDIO" checkout -q "$AUDIO_SHA" || die "mu300-audio 没有 commit $AUDIO_SHA"
	fi
fi

B=$KIT/build
mb=$OUT_ROOT/mod-build-$KREL
rm -rf "$mb"; mkdir -p "$mb/sprd_modem" "$mb/wcn_bsp" "$mb/sound" "$mb/audio_reserve"
cp -r "$AUDIO/kernel/mainline/sprd_audio" "$mb/sprd_audio"
cp -r "$KIT/ext/sprd_modem/kinclude" "$mb/sprd_modem/kinclude"
cp "$KIT/ext/sprd_modem/Module.symvers" "$mb/sprd_modem/Module.symvers" 2>/dev/null || true
cp -r "$KIT/ext/wcn_bsp/kinclude" "$mb/wcn_bsp/kinclude" 2>/dev/null || true
cp "$KIT/ext/dma/virt-dma.c" "$KIT/ext/dma/virt-dma.h" "$KIT/ext/dma/dmaengine.h" "$mb/sprd_audio/dma/" 2>/dev/null || true
# 新内核（7.3+）把 dma helper 挪进私有头，带外编要自带一份：见 build-kit.sh 里的说明
if [ -f "$KIT/ext/dma/NEEDS_PRIV" ]; then
	cp "$KIT/ext/dma/dmaengine_priv.h" "$mb/sprd_audio/dma/"
	for f in "$mb"/sprd_audio/dma/*.c; do
		grep -q 'dmaengine_priv.h' "$f" && continue
		{ echo '#include "dmaengine_priv.h"'; cat "$f"; } > "$f.tmp" && mv "$f.tmp" "$f"
	done
fi
cp -r "$AUDIO/kernel/mainline/sound/." "$mb/sound/"
cp -r "$KIT/ext/sound/." "$mb/sound/" 2>/dev/null || true
cp -r "$AUDIO/kernel/common/audio_reserve/." "$mb/audio_reserve/"

log=$OUT_ROOT/build-modules-$KREL.log
: > "$log"
for d in sound audio_reserve; do
	make -C "$B" ARCH=arm64 M="$mb/$d" -j"$JOBS" modules >>"$log" 2>&1 \
		|| { tail -n 30 "$log"; die "$d 编不过，日志 $log"; }
done
SYMS="$mb/sprd_modem/Module.symvers $mb/sound/Module.symvers"
make -C "$B" ARCH=arm64 M="$mb/sprd_audio" KBUILD_EXTRA_SYMBOLS="$SYMS" -j"$JOBS" modules >>"$log" 2>&1 \
	|| { tail -n 30 "$log"; die "sprd_audio 编不过，日志 $log"; }

OUT=$OUT_ROOT/modules-$KREL
rm -rf "$OUT"; mkdir -p "$OUT"
for ko in $(find "$mb/sprd_audio" "$mb/sound" "$mb/audio_reserve" -name '*.ko'); do
	# 和发行版一致：去 DWARF，留 .BTF
	strip --strip-debug -o "$OUT/${ko##*/}" "$ko" 2>/dev/null || cp "$ko" "$OUT/"
done
printf 'KEY=%s\nKREL=%s\nCONFIG=%s\nTAG=%s\n' "${KREL%%.*}" "$KREL" "$CONFIG_SHA" "$TAG" > "$OUT/KERNEL"

sh "$TOP/scripts/check.sh" "$OUT"
echo "== 模块好了: $OUT"
