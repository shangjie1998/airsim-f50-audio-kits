#!/bin/bash
# 校验一套模块：数量对、vermagic 对、补丁确实进了二进制。
#   scripts/check.sh out/modules-6.18.54
set -euo pipefail
TOP=$(cd "$(dirname "$0")/.." && pwd)
DIR=${1:?用法: scripts/check.sh <模块目录>}
KREL=$(sed -n 's/^KREL=//p' "$DIR/KERNEL" 2>/dev/null || true)
[ -n "$KREL" ] || { echo "check: $DIR 里没有 KERNEL" >&2; exit 1; }

miss=0; bad=0; n=0
while IFS= read -r m; do
	case $m in ''|'#'*) continue ;; esac
	n=$((n + 1))
	[ -f "$DIR/$m.ko" ] || { echo "  缺: $m.ko"; miss=$((miss + 1)); continue; }
	v=$(tr '\0' '\n' < "$DIR/$m.ko" | sed -n 's/^vermagic=//p' | head -n 1)
	case $v in "$KREL"|"$KREL "*) ;; *) echo "  vermagic 不对: $m.ko -> '$v'"; bad=$((bad + 1)) ;; esac
done < "$TOP/modules.txt"

# 补丁标记（mu300-audio 的每个补丁都会往对应模块里留一段字符串）
mark() { grep -aq "$2" "$DIR/$1.ko" 2>/dev/null || { echo "  $1.ko 里少了补丁标记 '$2'"; bad=$((bad + 1)); }; }
mark audio_sipc 'dropped a stale reply'
mark mcdt_hw_r2p0 'enabled the agcp mcdt clock'
mark snd-soc-sprd-card 'dummy_on_defer'
mark audio_mem 'shm_shift'
mark snd-soc-sprd-vbc-v4 'rejected (%d)'
mark agdsp_access 'power up timeout (bounded'
mark snd-soc-sprd-codec-ump9620 'still enabled, disabled before put'

echo "== 校验 $KREL：清单 ${n} 个，缺 ${miss}，问题 ${bad}"
[ "$miss" = 0 ] && [ "$bad" = 0 ]
