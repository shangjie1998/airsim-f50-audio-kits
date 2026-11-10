# 原理与排查

## 为什么必须按内核重编

`.ko` 里写着 `vermagic=6.18.54 SMP mod_unload aarch64`，内核加载时先比 vermagic，再比结构体布局（`struct module` 等）。两者只要有一项不同就报：

```
struct module size must match the kernel's built struct module size at run time
```

光改 vermagic 字符串没用——真正的差异是编译时那份 `.config`。所以**配置必须和运行内核一字不差**，这也是 `config/<KREL>.config` 存在的原因（从设备 `/proc/config.gz` 导出）。

## 两个阶段

1. **kit**：内核源码（kernel.org）→ 打 mu300-linux 的 `upstream/patches/6.18/*` → 用设备配置 `olddefconfig` → `modules_prepare` + `modules` 编出 in-tree 模块和 `Module.symvers` → 连同 sprd_modem / wcn_bsp 头文件、virt-dma 源码组成 `out/kit-<KREL>/`。
2. **modules**：拿 kit 当构建树，按 mu300-audio 的 `kernel/mainline/build-in.sh` 口径编 `sound`、`audio_reserve`、`sprd_audio` 三组源码，收集 25 个 `.ko`，`strip --strip-debug`。

## 判据（什么算成）

```
== 校验 6.18.54：清单 25 个，缺 0，问题 0
```

三项都过才算成：
- 25 个都在（`modules.txt`）
- 每个的 `vermagic` = `KREL`
- 每个补丁在二进制里留下了标记字符串（`audio_sipc` 的 `dropped a stale reply` 等）

真机再验一层：装上后 `/etc/airsim/no-audio` 自动消失，`ubus call airsim status` 的 `audio_available` 变 `true`。

## 排查表

| 现象 | 原因 | 怎么办 |
|---|---|---|
| 源码包 sha256 不符 | 下载被替换/不完整 | 从 kernel.org `sha256sums.asc` 复核，别直接用 |
| `构建树自报 X，和 KREL 不符` | 源码版本或版本后缀不对 | 确认下载的是 `linux-<KREL>.tar.xz`；检查 `.config` 的 `CONFIG_LOCALVERSION` |
| 补丁打不上 | mu300-linux 版本对不上源码 | `kits.lock` 的 release 换成与 KREL 同时期的；或手工 `patch --dry-run` 看偏移 |
| `in-tree modules 编不过` | 配置里有选项源码已删/依赖缺失 | 看 `out/work-<KREL>/modules.log` 第一个 error，`olddefconfig` 通常能兜住 |
| 编出来 `vermagic` 不对 | 构建树不是目标内核 | 别改字符串，重新造 kit |
| `Unknown symbol` | `Module.symvers` 不全或没带 `KBUILD_EXTRA_SYMBOLS` | 确认 kit 里 `Module.symvers` 存在、`sprd_modem`/`sound` 两份都传了 |
| 装上去静默不工作 | 两版内核的模块混用 | 检查 `KERNEL` 里的 `KREL` 和 `CONFIG` 是否就是设备那份 |
| `struct module size must match` 仍然报 | 配置不一致（最常见） | 重新 `zcat /proc/config.gz` 导出，比对 sha256 |

## 与插件侧的对接

插件（`airsim-f50-openwrt`）的音频可选件按 `KREL` 分目录放：

```
audio/f50/payload/<KREL>/        或者 payload/<KREL>+<tag>/
```

把 `out/modules-<KREL>/` 里的 25 个 `.ko` 和 `KERNEL` 拷进去，再 `sh audio/f50/make-opt.sh <KREL>` 打成一键安装包。插件启动时会比对 vermagic，对不上就自动跳过语音并留证据，不会卡住服务。
