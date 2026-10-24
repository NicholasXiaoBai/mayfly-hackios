# mayfly-hackios

把 Apple 开源的 **XNU 内核**（iOS 16 世代）搬到 **Xiaomi 12S**（`mayfly` / Qualcomm SM8475 /
骁龙 8+ Gen 1）上的移植工作区。

基于 [dipa-studio/ios-sweet](https://github.com/dipa-studio/ios-sweet) 的路线与代码（MIT），
参考 [XTOM0706/ios-sweet-k60](https://github.com/XTOM0706/ios-sweet-k60) 在 Redmi K60 上的
同 SoC 移植经验。

> 本项目不含任何苹果文件。iOS 的授权仅限苹果硬件，这是研究性质的工作。

## 当前状态

到 2026-10-24 为止，跑在真机上的是**裸机诊断 shim**（不是 iOS），它已经把 XNU 启动所需的
前置条件逐项验证完毕：

| 里程碑 | 状态 | 依据 |
|---|---|---|
| ABL 接受未签名镜像并跳入 | ✅ | `fastboot boot` 后设备离线 128 s，与 shim 设定一致 |
| 屏幕输出 | ✅ | `cont_splash_region` `0xb8000000`，1080×2400，stride 1080×4 |
| MMU + cache | ✅ | `MMU rc=0`，写屏 295 ms → 3.9 ms |
| GICv3 / Group1 / EOI | ✅ | `GICD 0xD0→0xD3`，`ICC_GRPEN1=1` |
| 虚拟定时器 | ✅ | 300 ms 窗口收到 30 次中断，`hppi=last=27` |
| SGI | ✅ | 自发 10 次，全部收到 |
| PSCI | ✅ | `ver=0x10001`，`CPU_ON` 支持 |
| 16 KB 页 | ✅ | `MMFR0.TGran16=1`，XNU 不必改 4 KB |
| UFS | ❌ | 命令返回 `OCS=2`，初始化不完整 |
| XNU 启动 | 未开始 | 需要 macOS 工具链，走 CI |

完整实测数据见 [docs/hardware.md](docs/hardware.md)。

## 构建

### Linux / CI

```sh
sudo apt-get install -y gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu
bash mayfly/shim/build-ci.sh
# -> mayfly/shim/out/shim-boot.img
```

### Windows（本地开发用）

需要一份 Zig（自带 aarch64 后端与 lld，不依赖 WSL / NDK）：

```sh
bash mayfly/shim/build-win.sh
```

Windows 上没有 `llvm-objcopy` / `nm` / `readelf` / `cpio`，因此这三件事由仓库里的
纯 Python 工具顶替：

| 工具 | 顶替 |
|---|---|
| `tools/elfinfo.py` | `objcopy -O binary`、`nm`、`readelf -r` |
| `tools/mkramdisk.py` | `cpio` |
| `tools/mkbootimg.py` | AOSP `mkbootimg`（支持 header v4） |
| `tools/fdt2dts.py` | `dtc -I dtb -O dts` |

## 刷入

```sh
adb reboot bootloader
fastboot boot mayfly/shim/out/shim-boot.img
```

**不写任何分区**。shim 会保持约 3 分钟后自己复位，之后 `fastboot reboot` 即可回安卓。

## 两个必须记住的坑

1. **boot header 必须是 v4。** 新 ABL 会静默忽略 v2：`fastboot` 报 `Booting OKAY`，
   然后设备直接启动原来的系统，没有任何报错。
2. **链接时不能开 `--gc-sections`。** `.text.head` 只被 `ENTRY(_head)` 引用，
   没有代码调用它，会被当成死代码丢掉，镜像开头就不是 ARM64 头了。

## 目录

```
mayfly/shim/     诊断 shim（C + asm，裸机 EL1）
tools/           跨平台构建辅助（纯 Python）
docs/hardware.md 小米 12S 的完整硬件图与实测数据
```

## 许可

本仓库代码沿用上游的 MIT 许可。shim 派生自 ios-sweet 的 `shim/`。
