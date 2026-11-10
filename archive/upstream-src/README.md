# 上游源码冷备份（git bundle）

上游哪天删仓库，产物还能用，但**没法再按新内核重编**——所以源码也要留一份。这里是 `git bundle`，不是压缩包，可以原样当远端用。

| 文件 | 体积 | 内容 |
|---|---|---|
| `mu300-linux.bundle` | 56 MB | `dikeckaan/mu300-linux` 全历史（132 个引用，HEAD `833616a6`）——内核源码、`upstream/patches/`、`upstream/modules/`、构建脚本 |
| `mu300-audio.bundle` | 1.3 MB | `kai-wu-cortex/mu300-audio` 全历史（22 个引用，HEAD `53cbe6a`）——音频驱动源码与 `kernel/build.sh`、`kernel/mainline/` 构建逻辑 |

## 怎么用

```sh
# 校验完整性
git bundle verify mu300-linux.bundle

# 当成远端克隆出来
git clone mu300-linux.bundle /tmp/mu300-linux
git clone mu300-audio.bundle /tmp/mu300-audio
```

## 为什么要它

- 产物（`.ko`、`Image`）只能解决"现在能用"，解决不了"上游换内核后要重编"
- 编一个内核要的是：源码 + 补丁 + 配置 + `Module.symvers` 生成过程，缺源码就断链
- bundle 体积小、可校验、可增量，比 tar 一份源码树好用

## 注意

- 这两份是**上游原文**，没做任何脱敏；里面 `kbuild/` 之类的默认地址 `root@192.168.77.1` 是上游出厂默认，不是我们的口令
- 这不是每天同步的镜像，需要更新时重新 `git clone --mirror` 再 bundle 一次即可
