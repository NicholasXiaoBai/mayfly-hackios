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
