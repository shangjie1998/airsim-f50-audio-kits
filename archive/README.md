# 上游产物冷存档

上游 `mu300-linux` / `mu300-audio` 会换内核基线（6.18.60 → 6.18.54 就是这么来的，新基线里连声音子系统都没编）。仓库被删或资产被换，靠它就别指望了，所以把**验证过能用的东西**存到我们这边。

## 存了什么

| 目录 | 内容 | 用途 |
|---|---|---|
| `6.18.60/airsim-audio-6.18.60.tar.gz` | 设备上跑通过的那套：25 个音频 `.ko` + `KERNEL` 元数据 + 两个补丁 + ABI 报告 + 工具清单 | 刷机丢了音频，直接解包装回；也是核对新编产物的对照基准 |
| `6.18.60/SHA256SUMS` | 上面各包的 sha256 | 校验 |
| `6.18.60/upstream/mu300-kernel-6.18.tar.gz` | 上游 `mu300-linux` 发布 **v2026.11.02.1** 的 6.18 内核原包（53 MB）：`Image`、`ramdisk-generic.lz4`、`kernel.config`、`kernel.release=6.18.60`、整棵 `modules/`（2956 个 `.ko`） | 上游换基线/删 release 后，本地这份就是唯一可复现的来源；编外置模块时的 `Module.symvers` 基准也从这里取 |

仓库没有 Release 写权限（PAT 403），所以大包也直接进 git，克隆大概 55 MB，换来的是"上游删了我也还在"。

## 用法

```sh
# 设备上恢复音频（6.18.60 内核）
tar xzf airsim-audio-6.18.60.tar.gz -C /mnt/mu300-disk/extra
# 然后插件维护页点「安装音频包」，或按 audio/f50/opt/install.sh 走
```

## 注意

- 这套 `.ko` 只对 **6.18.60** 内核有效（vermagic 钉死），换内核就是 `struct module size must match`。
- `6.18.54` 那版内核 `CONFIG_SOUND is not set`，没有 `snd_pcm_new` 这类符号，**任何**音频模块都装不上，不是包的问题。
