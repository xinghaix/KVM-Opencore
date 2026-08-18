# Hardware-specific VM notes

**Language:** [中文](hardware.zh-CN.md) · English

[Back to README](../README.md)

These settings live in **Proxmox / QEMU / libvirt**, not in the OpenCore ISO. OpenCore 1.0.7 does not replace them. The default `EFI/OC/config.plist` stays conservative (Penryn CPUID, `iMacPro1,1`, `boot-args=keepsyms=1`) so older guests and machines without a dGPU still boot.

Do not paste these extras into the shared ISO unless you have tested that hardware. Wrong GPU boot-args or a host CPUID spoof will brick other VMs that use the same image.

## Guest OS type: Other (USB 3.0)

On Proxmox, create the VM as **OS Type = Other** (`ostype: other`). Nick Sherlock’s Monterey/Ventura Proxmox guides say the same.

This is a **hypervisor** setting, not an OpenCore 1.0.7 key. “Other” keeps Proxmox from injecting Linux/Windows extras (USB tablet, balloon, a Windows-style xHCI) that conflict with macOS USB.

For USB 3 passthrough, the same guides and [OSX-KVM](https://github.com/kholia/OSX-KVM) also use:

```text
-device nec-usb-xhci,id=xhci,addr=0x8
-global nec-usb-xhci.msi=off
```

`msi=off` avoids QEMU panics when a USB 3 device is passed through. Some setups use `qemu-xhci` instead of `nec-usb-xhci`; if passthrough still dies, try the other controller plus `msi=off`.

Pass **whole USB controllers** (IOMMU group) when you can. Single-port passthrough is less reliable. Keep this image’s `USBPorts.kext`. Do not turn on `XhciPortLimit` unless you are on a very new guest and have tested it; OpenCore 1.0.7 only improved that quirk for macOS Tahoe.

## AMD RX 6600 XT (and other Navi)

Dortania’s [AMD GPU Buyers Guide](https://dortania.github.io/GPU-Buyers-Guide/modern-gpus/amd-gpu.html) lists Navi 23 (RX 6600 / 6600 XT) as working with **Lilu + WhateverGreen** and:

```text
agdpmod=pikera
```

Add that to `NVRAM → Add → 7C436110-AB2A-4BBB-A880-FE41995C9F82 → boot-args` **only** for Navi 10/20/23 cards. It can break Polaris (RX 580/590). This image does **not** ship `agdpmod=pikera` because the default tree must still boot VMs without a Navi card.

Also required on the **host / QEMU** side (not OpenCore quirks):

- SMBIOS `iMacPro1,1` (this image) or `MacPro7,1` so macOS treats the dGPU as the only GPU. A laptop iMac SMBIOS expects an iGPU.
- Do not keep a QEMU `std`/`vmware` display next to the passed-through card. Use `none` / no virtual VGA.
- Bind the GPU and its audio function to vfio; pass both. `video=efifb:off` on the host helps.
- Resizable BAR is a **firmware + QEMU** feature. It is not an OpenCore 1.0.7 performance switch.

There is no credible OpenCore 1.0.7 key that “makes a 6600 XT smoother and faster in benchmarks.” Display coming up at all is `agdpmod=pikera` + WEG. Extra frames usually come from: P-core-only `host-passthrough`, no extra virtual GPU, both GPU functions passed through, and a correct SMBIOS. Boot-args such as `unfairgva` / `shikigva` are for DRM / Apple TV, not 3D scores. Unofficial kexts (NootRX and similar) are out of scope here.

## Newer Intel CPUs

OpenCore’s KVM-facing CPU work is already in this image: `Kernel → Quirks → ProvideCurrentCpuInfo = true`. Nick Sherlock documents that this replaces the old topology patches and means `+invtsc` is no longer mandatory.

QEMU’s own manual still recommends **`host` / host-passthrough** when you do not live-migrate.

Use it like this on a **supported Intel** host:

```text
-cpu host,vendor=GenuineIntel,+invtsc,vmware-cpuid-freq=on,+ssse3,+sse4.2,+popcnt,+avx,+aes,+xsave,+xsaveopt,check
```

(`kvm=on` is the QEMU default.)

Then **clear** `Kernel → Emulate → Cpuid1Data` and `Cpuid1Mask` in a **private** copy of `config.plist`. The shared image spoofs Penryn (`0x00050654`). If you leave that spoof in place, macOS still sees Penryn even when QEMU exposes a 12th/13th/14th-gen host, and you lose the point of `host-passthrough`.

Do **not** change those two keys in the shared ISO. Penryn spoof is what lets older macOS and many AMD-host guests start.

### When `host` is a bad default

[LongQT-sea/qemu-cpu-guide](https://github.com/LongQT-sea/qemu-cpu-guide) and [LongQT-sea/OpenCore-ISO](https://github.com/LongQT-sea/OpenCore-ISO) default macOS guests to **`Skylake-Client-v4`** (macOS 10.11–26). That is a compatibility default, not a claim that Skylake benches higher than a working `host`.

Prefer a **named Intel model** (Skylake-Client / Cascadelake-Server, always `vendor=GenuineIntel`) when:

- The host is **AMD** (macOS needs an Intel vendor string).
- The host is **12th gen or newer with P+E cores**. macOS does not understand Intel hybrid topology; passthrough of E-cores is a common source of stalls and odd performance. Pin **P-cores only**, or use a named model.
- `host-passthrough` panics or the guest is stuck at Penryn-level features because you did not clear `Cpuid1Data`.

`libvirt.xml` in this tree still defaults to Penryn QEMU args, with `host` and `Skylake-Server` commented. That matches the conservative ISO. Flip those comments only after you test.

## What we borrowed

ISO-as-CD-ROM layout and the Skylake-vs-host discussion follow [LongQT-sea/OpenCore-ISO](https://github.com/LongQT-sea/OpenCore-ISO) and their CPU guide. USB `msi=off` and OS Type Other follow Nick Sherlock and OSX-KVM. GPU boot-args follow Dortania. None of those projects are replaced by this clone.
