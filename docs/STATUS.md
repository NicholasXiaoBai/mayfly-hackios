# 移植状态（2026-10-24 夜）

## 已打通

| 项 | 证据 |
|---|---|
| ABL 接受未签名 header v4 镜像 | `fastboot boot` 后设备离线 128 s，与设定一致 |
| 屏幕输出 | `cont_splash_region` `0xb8000000`，1080×2400，**stride 1080×4** |
| MMU + cache | `MMU rc=0`；写屏 295 ms → 3.9 ms |
| GICv3 Group1 / EOI | `GICD 0xD0→0xD3`，`ICC_GRPEN1=1` |
| 虚拟定时器 | 300 ms 窗口收到 30 次中断 |
| SGI | 自发 10 次全收到 |
| PSCI 1.1 / CPU_ON / 16 KB 页 | `ver=0x10001`，`MMFR0.TGran16=1` |
| **XNU 内核启动** | 屏幕出现内核 panic 文本，`SWEET EARLY 28: kprintf startup complete` |

## 卡住的地方

内核在 `_fiq_context_init + 0xc` 报 `Undefined kernel instruction`：

```
pc    = 0xfffffe0007491340      → _fiq_context_init + 0xc
指令  = 0xd51be328              → MSR CNTV_CTL_EL0, x8
ESR   = 0x20000000（EC=0）
```

### 已经排除的

| 假设 | 怎么排除的 |
|---|---|
| 内核跑在 EL2 | shim 在跳转前读 `CurrentEL` = **4**（EL1） |
| 指令被 mkpayload 的 fixup 改坏 | shim 读回该地址的 4 字节 = `D51BE328`，与文件一致 |
| phys_base 被截断成 32 位 | ADT 里实为 `0x840000000`；屏上 `40000000` 只是 `con_hex2` 的参数宽度截断 |

### 剩下的疑点

同样的 `MSR CNTV_CTL_EL0`，**shim 在 EL1 写得进去**（还收到 30 次中断），
内核在 EL1 却报未定义。说明中间有状态变化：

1. `CNTHCTL_EL2.EL1TVT` 被置位，把 EL1 的虚拟定时器访问 trap 到 EL2（最可能）
2. 或内核进入 FIQ 路径后 PSTATE/EL 有别于 shim
3. 注意同函数紧接着还写 `CNTP_CTL_EL0`（`0xd51be228`），而 shim 早已实测**这条在 EL1 就是未定义的**

## 下一步

1. 拉 `osfmk/arm64/fiq.c`（`fiq_context_init` 的实际所在），确认它读的那个寄存器（`S3_3_C4_C2_1`）是什么、bit 7 代表什么
2. 加一个 SWEET 专属补丁：在这条路径上跳过 `CNTV_CTL`/`CNTP_CTL` 的使能
   —— 我们平台的中断走 GIC Group 1（见补丁 0017），本来就不需要 Apple 那套 FIQ 定时器
3. 若仍失败，抓完整 `esr` 值（当前被屏幕右边界切掉），区分 EC=0x18（trap）与 EC=0x00（真未定义）

## 关键工程细节（踩过的坑）

- boot header **必须 v4**，新 ABL 静默忽略 v2
- 链接**不能开 `--gc-sections`**，`ENTRY` 引用的 `.text.head` 会被当死代码丢掉
- **`/chosen` 的 initrd 字段在 12S 上不可信**（报 6.8 MB，实际 payload 16.6 MB），
  所以 payload 改为追加在镜像尾部，`Image` 补齐到 `PAYLOAD_OFF=0x80000`，
  loader 用 `adr` 取基址定位
- shim 的 `con_hex2` 只接受 32 位，打印 64 位值会被截断显示（会误导排查）

---

## 更新：内核已越过首个 panic（2026-10-24 23:35）

补丁 **0082-mayfly-skip-arch-timers** 生效。`fiq_context_init()` 在 SWEET 下不再调用
`_enable_virtual_timer()`（它会连写 `CNTV_CTL_EL0` 与 `CNTP_CTL_EL0`，后者在本平台 EL1 上是
未定义指令）。

内核随即跑完下面这一整段：

```
SWEET GIC: built-in interface registered
SWEET NKE: AppleKeyStore registered (no passcode, unlocked)
SWEET NVR: IOWatchdog registered (accepts check-ins, never fires)
SWEET SURF: IOCoreSurfaceRoot registered
SWEET HID: buttons registered / touch registered
SWEET BATTERY: static fallback, 100% 4200mV external=1 charging=0
SWEET FB: AppleCLCD 1080x2400 stride 4320 at 0xb8000000, presented as 1125x2436
SWEET CPU: requested=1 selected=1 (limit=8)
SWEET CPU: cpu0 mpidr=0x0 came alive; SGI1 OK
KMC framework successfully initialized
using 11747 buffer headers and 7921 cluster IO buffer headers
SWEET CPU: 1/1 CPUs initialized, SGI1 verified
zone_init / pmap bootstrap done
standard timeslicing quantum is 10000 us
... configuring debugging over serial
```

即：平台专家、四个 SWEET 驱动、framebuffer、单核启动、内核内存管理全部就绪。

### 输出在这里停住

最后一行是 `configuring debugging over serial`。此后没有新的 kprintf，设备持续在线下（不自恢复）。
最可能是内核在等根设备（`rd=`），因为 payload 里没有根文件系统——`mkpayload --ramdisk` 没给。

### cmdline 注意

- `serial=3` 是**必须**的：改成 `serial=0` 后 fb 控制台不再输出，只剩 `SWEET EARLY 28` 一行黑屏
- `debug=0x8`（仅 kprintf）比 `0xc` 干净：后者会多打一条 KDB 初始化

## 下一个卡点：根文件系统

两条路，都不依赖再猜：

1. **ramfs 根卷**：ios-sweet 补丁 0021–0027 支持 RAM-disk root / mockfs，
   `mkpayload.py --ramdisk IMAGE` 会把镜像作为 md0 挂上，cmdline 加 `rd=md0`。
   好处是不碰 UFS 就能把内核推到 `launchd`。
2. **修 UFS**：shim 实测 `TUR/CAP/READ` 全部返回 `OCS=2`（invalid UTP task attribute），
   控制器起来了但命令被拒。要先对齐 uid/utrl 描述符格式与 PHY gear。

推荐先走 1，把内核推到用户态，再回头修 UFS。

---

## 2026-10-25 凌晨：UFS 与低窗实验

### UFS 在 shim 里是通的

shim 的独立探针（不经过内核）显示：

```
UFS TUR  rc=00000000  ocs/st=00000000
UFS CAP  rc=00000000  ocs/st=00000000
UFS READ rc=00000000  ocs/st=00000000
```

`ocs=0`（传输成功）、`st=0`（SCSI 成功）。早先看到的 `ocs/st=0x0002` 是两者打包打印
（`ocs << 8 | st`），实际是 **ocs=0 + st=2 (CHECK CONDITION)**，并不是 OCS 错误码。
**结论：控制器与颗粒通信正常，命令格式没问题。**

### 低窗实验失败，但失败点很有价值

把内核放到 4GB 以下（`MAYFLY_PHYS=0x80000000`、`MAYFLY_SIZE=0xBA00000`，186MB）以验证
"DMA 高位地址导致内核 UFS 失败"的假设。内核能启动，但在 framebuffer 映射处 panic：

```
SWEET EARLY 17: fbcon config read; mapping
SWEET EARLY PANIC: pmap_map_bd_with_options: no PTE for vaddr=0xfffffe000c000000,
  start=0xb0000000, end=0xbab00000, prot=0x3 @pmap.c:1835
```

原因：framebuffer 在 `0xb8000000`，而低窗的物理映射只覆盖 `0x80000000..0x8BA00000`，
`ml_io_map_wcomb()` 需要 physmap 里存在对应的 PTE。

**所以低窗不是干净的隔离手段**——要测 UFS 的 DMA 假设，得让内核继续用高窗，
改为让 UFS 驱动单独从低地址分配 DMA 缓冲。

### 当前最可靠的状态

| 配置 | 结果 |
|---|---|
| 高窗 0x840000000（9GB） | 内核跑到 `kdp_init` 之后停住，UFS 驱动报错 |
| 低窗 0x80000000（186MB） | 内核跑到 `SWEET EARLY 17`，framebuffer 映射 panic |

### 建议的下一步

1. 回到高窗配置
2. 给 `sweet_ufs.c` 加"低地址 DMA"：从 `0x80000000` 起的一段保留区分配 bounce buffer
   （而不是用 IOKit 从高窗分配），再观察命令是否成功 —— 这是唯一能干净验证
   4GB 假设的方法
3. 或者：给内核加一个**颜色标记**（UFS 成功画绿条、失败画红条），让判读不依赖拍小字
