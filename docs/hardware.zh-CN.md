# 硬件相关的虚拟机说明

**语言：** 中文 · [English](hardware.md)

[返回 README](../README.zh-CN.md)

这些项在 **Proxmox / QEMU / libvirt** 里改，不在 OpenCore ISO 里。OpenCore 1.0.7 不会自动替你改好。仓库默认的 `EFI/OC/config.plist` 仍然偏保守（Penryn CPUID、`iMacPro1,1`、`boot-args=keepsyms=1`），这样没独显、或要跑旧系统的虚拟机还能启动。

不要把下面这些“针对某块卡/某颗 CPU”的参数写进共用 ISO，除非你已经在那台机器上测过。错误的显卡 boot-args 或宿主 CPUID 伪装，会让用同一张盘的其他虚拟机起不来。

## 客户机类型选 Other（USB 3.0 直通）

在 Proxmox 里创建虚拟机时，**OS Type 选 Other**（`ostype: other`）。Nick Sherlock 的 Monterey / Ventura Proxmox 教程也是这样写的。

这是**虚拟机管理器**的选项，不是 OpenCore 1.0.7 的新键。选 Other 是为了避免 Proxmox 按 Linux/Windows 塞进 USB tablet、气球内存、Windows 风格 xHCI，这些经常和 macOS 的 USB 冲突。

USB 3 直通时，同一批教程和 [OSX-KVM](https://github.com/kholia/OSX-KVM) 还会加上：

```text
-device nec-usb-xhci,id=xhci,addr=0x8
-global nec-usb-xhci.msi=off
```

`msi=off` 是为了避免直通 USB 3 设备时 QEMU 崩溃。有的环境用 `qemu-xhci` 比 `nec-usb-xhci` 稳；如果还是断，换控制器并保持 `msi=off`。

能整卡直通（整个 IOMMU 组）就不要只直通单个口。本镜像的 `USBPorts.kext` 留着。不要随便打开 `XhciPortLimit`，除非你在很新的系统上测过；OpenCore 1.0.7 只是把这个 quirk 对 macOS Tahoe 做得更稳一些。

## AMD RX 6600 XT（以及其他 Navi）

Dortania 的 [AMD GPU 购买指南](https://dortania.github.io/GPU-Buyers-Guide/modern-gpus/amd-gpu.html) 写明：Navi 23（RX 6600 / 6600 XT）可用，前提是 **Lilu + WhateverGreen**，并且 boot-args 带：

```text
agdpmod=pikera
```

只给 Navi 10/20/23 加这一项。它可能搞坏 Polaris（RX 580/590）。本镜像**默认不加** `agdpmod=pikera`，因为还要照顾没有 Navi 的虚拟机。

另外要在 **宿主机 / QEMU** 上做（不是 OpenCore 里某个 1.0.7 新开关）：

- SMBIOS 用 `iMacPro1,1`（本镜像默认）或 `MacPro7,1`，让系统把独显当唯一 GPU。笔记本 iMac 机型会去找核显。
- 直通独显后不要再挂 QEMU 的 `std`/`vmware` 虚拟显卡，显示选 `none`。
- GPU 和音频功能一起绑 vfio、一起直通。宿主机内核参数可加 `video=efifb:off`。
- Resizable BAR 是**主板固件 + QEMU** 的能力，不是 OpenCore 1.0.7 的跑分开关。

没有可信资料表明 OpenCore 1.0.7 里有某个参数能让 6600 XT“画面更流畅、跑分更强”。能出画面，靠的是 `agdpmod=pikera` + WEG。帧数和分数通常来自：只直通 P 核的 `host-passthrough`、去掉多余虚拟显卡、GPU 两个功能都直通、机型选对。`unfairgva` / `shikigva` 是给 DRM / Apple TV 用的，不是 3D 跑分项。NootRX 这类非官方 kext 不在本仓库范围。

## 较新的 Intel CPU

OpenCore 面向 KVM 的 CPU 工作，本镜像已经开了：`Kernel → Quirks → ProvideCurrentCpuInfo = true`。Nick Sherlock 写过：它取代了旧的拓扑补丁，因此不再强制 `+invtsc`。

QEMU 自己的文档在不需要热迁移时，仍然建议 **`host` / host-passthrough**。

在**受支持的 Intel** 宿主机上可以这样用：

```text
-cpu host,vendor=GenuineIntel,+invtsc,vmware-cpuid-freq=on,+ssse3,+sse4.2,+popcnt,+avx,+aes,+xsave,+xsaveopt,check
```

（`kvm=on` 是 QEMU 默认值。）

然后在**你自己的** `config.plist` 副本里，把 `Kernel → Emulate → Cpuid1Data` 和 `Cpuid1Mask` **清空**。共用镜像里这两项会伪装成 Penryn（`0x00050654`）。如果不清掉，即使 QEMU 暴露的是 12/13/14 代宿主 CPU，macOS 看到的仍是 Penryn，`host-passthrough` 就没有意义。

**不要**改共用 ISO 里这两项。Penryn 伪装是为了让旧系统和很多 AMD 宿主机上的客户机还能启动。

### 什么时候不该用 `host`

[LongQT-sea/qemu-cpu-guide](https://github.com/LongQT-sea/qemu-cpu-guide) 和 [LongQT-sea/OpenCore-ISO](https://github.com/LongQT-sea/OpenCore-ISO) 把 macOS 客户机默认 CPU 设成 **`Skylake-Client-v4`**（覆盖 10.11–26）。这是兼容性默认值，不是说 Skylake 一定比能正常工作的 `host` 跑分更高。

遇到下面情况，改用**具名 Intel 型号**（Skylake-Client / Cascadelake-Server，并始终 `vendor=GenuineIntel`）：

- 宿主机是 **AMD**（macOS 需要 Intel 厂商字符串）。
- 宿主机是 **12 代及更新的大小核**。macOS 不理解 Intel 混合架构，把 E 核也透进去很容易卡顿、性能怪异。只绑定 **P 核**，或改用具名型号。
- `host-passthrough` 直接 panic，或你没清 `Cpuid1Data`，客户机一直停在 Penryn 特性集。

本仓库 `libvirt.xml` 默认仍是 Penryn 的 qemu 参数，`host` 和 `Skylake-Server` 写在注释里，和保守 ISO 一致。改之前先测。

## 文档借鉴来源

光盘 ISO 的用法，以及 Skylake 和 `host` 怎么选，参考了 [LongQT-sea/OpenCore-ISO](https://github.com/LongQT-sea/OpenCore-ISO) 和他们的 CPU 指南。USB `msi=off`、OS Type Other 来自 Nick Sherlock 和 OSX-KVM。显卡 boot-args 来自 Dortania。这些项目都不会被这个克隆仓库替代。
