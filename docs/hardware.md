# 小米 12S（mayfly / SM8475）硬件图

> 采集时间：2026-10-24
> 来源：本机 live FDT（`/sys/firmware/fdt`，root 导出）+ `/proc/cmdline` + dmesg + sysfs
> 工具：`tools/fdt2dts.py`（自写，纯标准库，替代 dtc）
> 原始文件：`facts/mayfly-live.dtb`、`facts/mayfly-live.dts`（30436 行）

## 0. 设备状态

| 项 | 值 | 来源 |
|---|---|---|
| 代号 / 型号 | `mayfly` / 2206123SC | `ro.product.device` |
| 平台 | `taro`，compatible `qcom,cape-mtp` / `qcom,cape` | DT 根节点 |
| SoC | SM8475，X2 + 3×A710 + 4×A510，MPIDR `0x000–0x700` | DT `cpus` |
| 系统 | 澎湃 OS 3.0（`OS3.0.45.0.WPBCNXM`），Android 16 | `ro.build.version.incremental` |
| Bootloader | `verifiedbootstate=orange` → **已解锁** | `ro.boot.*` |
| Root | Magisk（`su` 可用，`context=u:r:magisk:s0`） | `su -c id` |
| 当前槽位 | `_a` | `ro.boot.slot_suffix` |

## 1. 中断与定时器

| 项 | 值 |
|---|---|
| GICD | `0x17100000`，size `0x10000` |
| GICR | `0x17180000`，size `0x200000`，stride `0x40000` |
| GIC ITS | `0x17140000` |
| 定时器频率 | `0x124f800` = 19,200,000 Hz |
| PPI 分配 | secure-phys 13、non-secure-phys 14、**virtual 11**、hyp 12 |
| 虚拟定时器 INTID | 16 + 11 = **27** |

DT 原文：`interrupt-controller@17100000 { compatible = "arm,gic-v3"; reg = <0x17100000 0x10000 0x17180000 0x200000>; }`

## 2. 存储

| 项 | 值 |
|---|---|
| UFS 主控 | `0x1d84000`（`ufs_mem`，`0x3000`） |
| UFS ICE | `0x1d88000`（`0x8000`） |
| UFS ICE HWKM | `0x1d90000`（`0x9000`） |
| 类型 | UFS 3.1，逻辑块 4096 |

## 3. 内存布局

DT `memory` 节点（`#address-cells=2`）：

| 区间 | 大小 |
|---|---|
| `0x0_80000000` | `0x6a000000`（1.66 GB） |
| `0x0_f4600000` | `0x0ba00000`（186 MB） |
| `0x8_00000000` | `0x37500000` |
| `0x8_37b00000` | `0x01e00000` |
| `0x8_40000000` | — |
| `0x9_00000000` | `0x180000000`（6 GB） |

**可用大块**：`0x840000000` – `0xa7fffffff`，连续 **9 GB**，内部无任何固定 carve-out。
所有固定保留区（`mpss` `0x8bc00000`、`adsp` `0x9fd00000`、`tz` `0xe8800000`、`qtee` `0xe9b00000` 等 37 个）都在 `0xf0000000` 以下。

→ `PAYLOAD_BASE` 建议 `0x840000000`（与 K60 相同）。

## 4. 显示

| 项 | 值 |
|---|---|
| 面板节点 | `qcom,mdss_dsi_l3s_42_02_0a_dsc_cmd` |
| 面板名 | `"xiaomi 42 02 0a mp cmd mode dsc dsi panel"` |
| 分辨率 | `0x438 × 0x960` = **1080 × 2400** |
| 刷新率 | 120 / 90 / 60 Hz（`timing@1` / `timing@2` / `timing@0`） |
| 模式 | **DSC command mode**（`mp cmd mode`） |
| 时序（dmesg 实测） | h: 1080/32/16/32，v: 2400/32/16/64，`clk_rate=832000000` |
| 背光 | `bl_ctrl_dcs`，DC 调光，local HBM |
| panel-id | `0x4c3353`（"L3S"） |

**开机画面缓冲区**：

```
splash_region {
    label = "cont_splash_region";
    reg = <0x0 0xb8000000 0x0 0x2b00000>;   // 43 MB
};
```

⚠️ 整个 DT 里只有这一处和 splash 有关，**没有任何 cont-splash 交接属性**（`grep -i splash` 仅 2 行）。
这一点与 K60 完全一致——K60 就是在同样的配置下发现 ABL 会关掉面板。所以 12S 能不能复用这个缓冲区，
仍然必须用 shim 实测，不能推断。

## 5. 触控 —— FocalTech（与另外两台 SM8475 设备都不同）

| 项 | 值 |
|---|---|
| 控制器 | **FocalTech**（节点 `fts@0`，compatible `st,spi`） |
| 总线 | `spi@990000`（QUPv3 SE4），`0x4000` 长 |
| SPI 频率 | 控制器 `0x2faf080`(50 MHz)，设备 `0xb71b00`(**12 MHz**) |
| GIC 中断 | SPI `0x25d` = **605** |
| IRQ GPIO | TLMM **gpio 21**（`0x15`），flags `0x2008`（上升沿） |
| Reset GPIO | TLMM **gpio 20**（`0x14`） |
| 供电 | `avdd-supply` / `vdd-supply`（regulator phandle） |
| 固件 | `/vendor/firmware/st_fts_l3s.ftb`、`st_fts_l3s_thp.ftb` |
| 内核里看到的设备名 | input `fts`（另有一个 `uinput-goodix` 是**屏下指纹**，别搞混） |

## 6. 按键与电源

- 输入设备：`pmic_pwrkey`、`pmic_resin`（电源键 / 音量）、`gpio-keys`、`qcom-hv-haptics`
- **PSHOLD 不存在**（SM8475 走 PMIC PON + SPMI），软复位只能用 `PSCI_SYSTEM_RESET`
- 调试串口：`console=ttyMSM0,115200n8`（`qcom,qup_uart@99c000`），物理未引出 → 屏幕是唯一信息通道

## 7. 与另外两台 SM8475 设备的对照

| 项 | Redmi K60 (mondrian) | **小米 12S (mayfly)** | 平板 6 Pro (liuqin) |
|---|---|---|---|
| GICD / GICR | `0x17100000` / `0x17180000` | **相同** | 相同 |
| 定时器 INTID | 27 | **27** | 27 |
| UFS | `0x1d84000` | **相同** | 相同 |
| 高窗内存起点 | `0x840000000`（9 GB） | **相同** | 6 GB 窗 |
| splash 保留区 | `0xb8000000` 43 MB | **相同** | — |
| 触控 SPI 控制器 | `spi@990000` | **`spi@990000`** | `spi@990000` |
| 触控芯片 | Goodix m11a | **FocalTech `st_fts_l3s`** | Novatek NT36532 |
| 面板 | 1440×3200 DSC cmd | **1080×2400 DSC cmd** | 1800×2880 画布 |
| 显示能否白嫖 ABL | ❌ ABL 关面板 | **待实测** | ✅ 可用 ABL framebuffer |

**结论**：SoC 级别的东西（中断、定时器、存储、内存布局、SPI 控制器）完全可复用；
真正要自己写的只有两样——**FocalTech 触控协议**和**这块 1080×2400 面板的点屏序列**。

---

## 9. 实机探针结果（2026-10-24 22:13，shim 屏幕上实测）

### 显示 —— 通过，且是"免费"的

| 项 | 实测 |
|---|---|
| framebuffer 基址 | `0xb8000000`（cont_splash_region） |
| 分辨率 | 1080 × 2400 |
| **stride** | **1080 × 4 = 4320**（不是 1088！按 1088 画会把文字糊成横条纹） |
| 像素格式 | 按 `0xAARRGGBB` 写入即可正确显示（`0xffff0000` → 红） |
| ABL 是否保留面板 | **是**。ABL 交接后 DPU 仍在从该缓冲区取帧，写入即时可见 |

这一条推翻了之前的担心：虽然是 DSC command mode 面板，但 ABL 留下的显示通路是活的，
可以像 HackiOS / ios-sweet 在其它机型上那样直接往 framebuffer 画。显示不再是瓶颈。

### PSCI / SMCCC

| 项 | 值 | 含义 |
|---|---|---|
| PSCI 版本 | `0x00010001` | PSCI 1.1，够用 |
| SMCCC 版本 | `0x00010001` | SMCCC 1.1 |
| `PSCI_FEATURES(CPU_ON)` | `0x00000000` | **支持**，副核能起来 |
| `PSCI_FEATURES(SYSTEM_RESET2)` | `0x00000000` | **支持** |

### CPU

| 项 | 值 | 含义 |
|---|---|---|
| MPIDR_EL1 | `0x81000000` | 启动核 Aff0=0、Aff1=0 |
| MIDR_EL1 | `0x410FD463` | ARM，partnum `0xD46` = **Cortex-A510**（ABL 在小核上启动） |
| ID_AA64MMFR0_EL1 | `0x0000002200101122` | **TGran16 = 1 → 支持 16KB 页**；TGran4 = 0 → 也支持 4KB |
| ID_AA64PFR0_EL1 | `0x1201101003111111` | EL2、EL3 均已实现，FP/AdvSIMD 在位 |

**TGran16 支持是本轮最重要的一条**：XNU 默认按 16KB 页组织，这条成立意味着不需要像
UniXNU 那样把内核改成 4KB 页，可以省掉一整类补丁。

### UFS —— 未通

```
UFS   ver=0x00000300  cap=0x1587031f
UFS   hce=00000001  hcs=0000010f
UFS   is=00000400  rsr=00000001
UFS   utrlba=FF12C000 hi=00000000
UFS   dbr=00000000  nutrs=00000020
UFS   ours=0x00016000  rsr=00000001
UFS   TUR  rc=00000004  ocs/st=00000002   （连续 4 次）
UFS   CAP  rc=00000004  ocs/st=00000002
UFS   READ rc=00000004  ocs/st=00000002
```

控制器起来了（HCE=1、HCS 显示 link 状态、UTRL 已配置），但所有命令返回
`OCS = 2`（invalid UTP task attribute）+ SCSI status 错误。
即 host controller 活着、命令被拒——典型的 UFS 初始化不完整（PHY/gear/clock 或
UTP 描述符格式问题），需要对照 K60 的 `ufs.c` 逐段核。这是 M5 的活，不影响先跑 XNU。

### 时间线实测

| 时刻 | 事件 |
|---|---|
| `fastboot boot` +0s | ABL 接受镜像并跳入 |
| +6s ~ +134s | 设备完全离线（我们的代码在跑，无 USB 协议栈） |
| +141s | 安卓回来 |

shim 设定保持 120s + 复位 5s，安卓冷启动约 16s，与实测严丝合缝。

## 10. 完整诊断套件结果（2026-10-24 22:20）—— XNU 前置条件全部通过

### 引导与内存

| 项 | 实测 | 判定 |
|---|---|---|
| `DTB at` | `0xB6759000`，magic `D00DFEED` | ✅ ABL 正常传入设备树 |
| `IMAGE lo/hi` | `0xAB000000` – `0xAB040000` | ✅ 镜像装载基址（ELR 反查用得上） |
| `MMU rc` | `0` | ✅ 页表建立成功，`l3=1` |
| `TTBR0 pa` | `0xAB010000` | 页表在镜像内 |
| `SCTLR` | `0x30B009B0` → `0x30B0199D` | ✅ M/C/I 位已置，MMU + D-cache + I-cache 开 |
| `TCR` | `0x140C5B1C` | 16K 页配置 |
| `MMFR0 / tg16` | `0x2 / 0x1` | ✅ PARange 40 位，16K 粒度支持 |
| `PAR img` | 无 fault，PA=`0xAB001xxx` | ✅ 恒等映射正确 |
| `PAR gic` | 无 fault，PA=`0x17100xxx` | ✅ |
| `PAR 12G` | **fault**（`0xBD`，bit0=1） | ✅ 未映射区确实会 fault，说明页表不是全开 |

### cache 生效的硬证据

```
FILL us  off=0x47F23 (294,691)  on=0x00F42 (3,906)     → 提速 75×
MEM  us  off=0x0D046 ( 53,318)  on=0x0017C (  380)     → 提速 140×
```

打开 MMU/D-cache 后，写满一屏从 295 ms 降到 3.9 ms。这证明写合并与 cache 属性配对了，
后面 XNU 的 framebuffer 性能不会是问题。

### GICv3 + 定时器 —— 全部工作

| 项 | 实测 | 含义 |
|---|---|---|
| `GICD was→now` | `0xD0` → `0xD3` | ✅ Group1 使能，ARE 在位 |
| `GICR base / waker` | `0x17180000` / `0` | ✅ redistributor 已唤醒 |
| `ENABLE was→now` | `0` → `0x49000002` | ✅ INTID 1（SGI1）与 27（vtimer）已使能 |
| `ICC ctlr / grpen1` | `0xB8400` / `1` | ✅ Group1 中断通路开 |
| **`VTIMER irqs`** | **`0x1E` = 30** | ✅ 300 ms 窗口 / 10 ms 周期，一个不差 |
| `VTIMER other` | `0` | ✅ 没有杂散中断 |
| `VTIMER hppi / last` | 均为 `0x1B`（27） | ✅ 挂起与最后响应的都是 vtimer |
| `tctl` | `5` = ENABLE\|ISTATUS | ✅ 定时器条件成立 |
| **`SGI1 irqs`** | **`0x0A` = 10** | ✅ 自发 SGI 10 次，全部收到 |
| `SGI1 last` | `0x1` | ✅ EOI 路径正常 |

**结论：GICv3 分发、redistributor、Group1、EOI、虚拟定时器、SGI 全部在 EL1 下打通。**
这是 XNU 中断子系统能起来的最小充分条件。

### 踩到的坑（已修）

`irq_window()` 结尾无条件写了 `CNTP_CTL_EL0`（物理定时器）。SM8475 的 EL2 把 EL1 的物理定时器
访问 trap 掉了，这条 `MSR` 在 EL1 是**未定义指令**：

```
PANIC SYNC / STAGE=gic vtimer / ESR=0x20000000（EC=0，Unknown reason）
ELR=0xAB0027C0 → 镜像偏移 0x27C0 → irq_window+0x1C0 → 0xD51BE22A = MSR CNTP_CTL_EL0, x10
```

修法：只清真正启动过的那个定时器；并且把结果打印挪到清理之前，避免数据被 panic 屏覆盖。

### 仍未解决

- **UFS**：`OCS=2`（invalid UTP task attribute），控制器活着但命令被拒 → M5
