# F50 语音模块构建仓库

给中兴 F50（UMS9620）编 **通话语音驱动**（25 个 `.ko`）。解决的问题只有一个：

> 设备内核换了，手上那套 `.ko` 装上就被内核拒（`struct module size must match the kernel's built struct module size at run time`）。

内核只认跟自己同一份配置编出来的模块，所以每个内核版本都得单独编一套。这个仓库就是干这个的，可复现、可追溯。

## 三条路，先选一条

| 路线 | 做法 | 代价 |
|---|---|---|
| A 换回旧系统镜像 | 比如刷回 `mu300-r20261106…`（内核 6.18.60），现成的模块直接用 | 要重刷机 |
| B 自己编（本仓库） | 按新内核重编 25 个 `.ko`，打可选件包 | 一次编译，之后可复用 |
| C 不编 | 插件自动检测到内核不匹配就跳过语音，页面/短信/来电通知照常 | 没有通话语音 |

## 云端一键编（推荐，不用装 Docker）

本仓库用 GitHub Actions 的 **arm64** 机器编，公开仓库**免费**。

1. 仓库页 → **Actions** → 左侧「编音频模块」→ **Run workflow**
2. `krel` 填内核版本（要 `kits.lock` 里有、`config/` 下有同名配置），比如 `6.18.54`
3. 编完在本次运行的 **Artifacts** 里下载 `audio-modules`（里面是 tar.gz + sha256）

打 tag 推送（`k-6.18.54`）会自动把包发到 Release。

## 本机编（Linux / macOS 都行，arm64 最省事）

```sh
scripts/build-kit.sh 6.18.54          # 拉源码、打补丁、按设备配置编出构建树 → out/kit-6.18.54
scripts/build-modules.sh 6.18.54      # 编 25 个模块 → out/modules-6.18.54
```

依赖：`build-essential`（或 Xcode CLT）、`bc bison flex libssl-dev libelf-dev patch xz git curl`。
ARM 机器上直接编；x86 上要么装 aarch64 交叉工具链并把 `ARCH/CROSS_COMPILE` 传进去，要么用 CI。

## 目录

```
kits.lock                 要编哪些内核：KREL / 源码 sha256 / 配置 sha256 / mu300-linux release / mu300-audio commit
config/<KREL>.config      设备 /proc/config.gz 导出的真实配置（这是能编对的前提）
modules.txt               25 个模块清单
sources.json              上游出处（内核仓、音频仓、系统镜像版本）
scripts/build-kit.sh      源码 + 补丁 + 配置 → 构建树
scripts/build-modules.sh  构建树 + 音频源码 → 25 个 .ko
scripts/check.sh          数量 / vermagic / 补丁标记三连校验
docs/rebuild.md           原理、失败判据、排查
```

## 加一个新内核版本

1. 从设备取配置：`zcat /proc/config.gz > config/<KREL>.config`
2. 算 sha256，追加一行到 `kits.lock`（源码 sha256 从 kernel.org 的 `sha256sums.asc` 里取）
3. 跑 `scripts/build-kit.sh <KREL>`，再 `scripts/build-modules.sh <KREL>`
4. 编出来的包丢给插件的音频可选件安装（按 `KREL` 分目录，见 `docs/rebuild.md`）

## 合规

- 驱动源码 GPL-2.0（[mu300-audio](https://github.com/kai-wu-cortex/mu300-audio)），内核 GPL-2.0。
- 本仓库不包含任何厂商闭源件（DSP 固件 `agdsp.bin`、`mu300-audio-dsp`、`ctlset`、`pcmhost` 等），也不包含 `.ko` 二进制。
- 分发编译产物时，源码与构建方法即本仓库 + `sources.json` 记录的版本，一并保留说明。

## 现状与限制

- `6.18.54` 这套**上游从未发布过**（上游只做过 6.18.57/6.18.58），所以由本仓库自制 kit。
- 首次云端构建可能踩到补丁偏移、config 选项差异，按 `docs/rebuild.md` 的排查表处理；跑通一次后就是稳定的。
- 编译产物与插件侧的对接见另一仓库 `airsim-f50-openwrt` 的 `audio/f50/`。
