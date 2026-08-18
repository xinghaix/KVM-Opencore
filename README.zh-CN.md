# KVM-Opencore

**语言：** 中文 · [English](README.md)

QEMU/KVM 专用的 OpenCore 镜像。官方 OpenCore 只保证真机/Hackintosh，本仓库把 **QEMU + OVMF + q35** 上不能乱改的引导项写成契约，升级时必须先对照变更再打包。

本仓库只是 [thenickdude/KVM-Opencore](https://github.com/thenickdude/KVM-Opencore) 的**克隆**（其源头是 [Leoyzen/KVM-Opencore](https://github.com/leoyzen/KVM-Opencore)），不是新的上游项目。这里只加了自己的 QEMU/KVM 自定义配置、自动发版工作流，以及下文的升级/兼容性检查。

Release ISO 按 CD-ROM 挂载（做法参考 [LongQT-sea/OpenCore-ISO](https://github.com/LongQT-sea/OpenCore-ISO)）。Proxmox OS Type 选 Other、USB 3、Navi / RX 6600 XT、较新的 Intel CPU 等，写在 [docs/hardware.zh-CN.md](docs/hardware.zh-CN.md)。那些是虚拟机侧的修改，不会偷偷改共用的 `config.plist`。

## 这是什么

GitHub Actions 下载 [acidanthera](https://github.com/acidanthera) 的官方 RELEASE 包，叠上本仓库的 `EFI/OC/config.plist`、ACPI 和自定义 kext，用**同一版本**的 `ocvalidate` 校验，再跑 `scripts/kvm-compat.json` 契约检查，最后发布：

- `OpenCore-<tag>.iso` — 真正的 ISO 9660 + UEFI El Torito 光盘。上传到 ISO 存储后按 **CD-ROM** 挂载，不用改成硬盘。
- `OpenCore-<tag>.iso.gz` — 同一张 ISO 的 gzip 压缩包
- `OpenCoreEFIFolder-<tag>.zip` — 现成的 `EFI/`
- `upgrade-review.md` — **当前钉住的 OpenCore → 这次构建目标版本** 的官方 Changelog 摘录
- `Configuration.pdf` / `SHA256SUMS`

当前镜像按 Catalina / Big Sur / Monterey / Ventura 方向维护，更新的 macOS 需要先走下面的升级流程，不要假设能直接启动。

## 为什么不能只换核心

`package-release.sh` 换的是官方二进制，**不会**自动理解 1.0.7 到 1.0.8 之间改了什么。新版可能：

- 新增 `config.plist` 键，缺了 `ocvalidate` 直接失败
- 旧键的**官方推荐值**变了：有的能提升虚拟机性能或修已有问题，有的跟了就会砖掉 KVM
- Sample 默认值对真机合适、对 KVM 是致命的（例如 `Vault=Secure`、`SecureBootModel=Default`、`SetupVirtualMap=true`、`ClearTaskSwitchBit=true`）
- 改 VirtIO / 引导设备 / SMBIOS / CPU 行为，虚拟机进不了系统
- kext 的 `MinKernel`/`MaxKernel` 写错会再次出现开机十几分钟（v21 修过的蓝牙问题）

所以升级是固定流程，不是“把 `opencore_version` 改成 latest 再点 Run workflow”，也**不是**永远锁死旧值、错过官方修 bug。

## 新参数和旧参数新值：三类处理

`review-upgrade.py` 会对照目标版 `Sample.plist`，把差异分成三类。打包脚本**不会**自动改已有值。

| 类型 | 怎么处理 |
| --- | --- |
| **新键** | 必须单独决定 KVM 默认值，写进 `EFI/OC/config.plist`。Sample 默认值只能当参考。若 Sample 不安全，把我们的值锁进 `scripts/kvm-compat.json`。 |
| **契约锁死的旧键** | 即使 Sample 改了也不跟。例如 `DummyPowerManagement=true`、`SetupVirtualMap=false`、`Vault=Optional`。只有有意改变 KVM 策略时才改契约。 |
| **未锁死、但和 Sample 不一致的旧键** | 这才是性能或修问题的候选。对照 Changelog，改 `config.plist`，用旧盘做回滚测虚拟机，确认有益再提交。 |

当前相对 OpenCore 1.0.7 Sample 的例子：

- 候选：`FixupAppleEfiImages` 我们是 `false`，官方已默认 `true`（修较新/损坏的 Apple EFI 引导）。装新系统前应评估是否打开。
- 不要跟 Sample：`SetupVirtualMap`、`SecureBootModel`、`Vault`、`Timeout`、`DummyPowerManagement`。
- 不要当性能项：MLB / ROM / 序列号 / UUID。

## 升级必备流程（按顺序）

不要跳步。契约检查失败的包**不准发正式版**。

1. **看当前钉住的版本和上游最新版差了什么**

   ```bash
   python3 scripts/review-upgrade.py --to latest
   ```

   默认从 `scripts/component-versions.env` 的 `OPENCORE_VERSION` 比到官方最新 tag。
   先读输出里所有 **`[KVM]`** 行和三张 Sample 对照表，再打开官方 [Changelog](https://github.com/acidanthera/OpenCorePkg/blob/master/Docs/Changelog.md) 和 [Differences](https://dortania.github.io/OpenCore-Install-Guide/differences.html)。

2. **按三类处理 plist，禁止整份粘贴 Sample.plist**

   用 `scripts/ensure_oc_config.py` 只补**缺失**键。
   然后打开 `review-upgrade.py` 的三张表：新键写进仓库；锁定键保持；候选键逐条评估（该修的修，该提升的提升）。
   不要只把新键留在打包临时目录。

3. **跑契约检查**

   ```bash
   python3 scripts/check-kvm-compat.py EFI/OC/config.plist
   make check
   ```

   契约在 `scripts/kvm-compat.json`，至少包括：

   | 项 | 必须值 | 原因 |
   | --- | --- | --- |
   | `DummyPowerManagement` | `true` | QEMU 没有真 SMC |
   | `ProvideCurrentCpuInfo` | `true` | host-passthrough / Penryn 拓扑 |
   | `SetApfsTrimTimeout` | `0` | 虚拟盘开机 TRIM 极慢 |
   | `SetupVirtualMap` | `false` | 不少 OVMF 上会无法引导 |
   | `ClearTaskSwitchBit` | `false` | 那是 Hyper-V 开关 |
   | `SecureBootModel` | `Disabled` | 虚拟 SMBIOS 不是真机 |
   | `Vault` | `Optional` | Sample 的 `Secure` 会砖掉镜像 |
   | `Timeout` | `0` | 非 0 时安装器可能套娃 |
   | `SystemProductName` | `iMacPro1,1` | 本镜像默认机型 |
   | `Cpuid1Data` | Penryn `54060500…` | 让 macOS 接受虚拟 CPU |
   | `BrcmBluetoothInjector` MaxKernel | `20.99.99` | Monterey+ 加载会开机极慢 |
   | `VirtualSMC` | **关闭** | 这里用 DummyPowerManagement |
   | `CryptexFixup` | 开启 | 无 AVX2 的宿主机跑 Ventura+ |

4. **用目标版本的 ocvalidate，不要用旧的**

   旧 Configurator / 旧 `ocvalidate` 看不出新键，也放不过新规则。

5. **先 draft，旧盘留着当回滚**

   ```bash
   ./scripts/package-release.sh --version v23 --opencore 1.0.8
   ```

   或在 Actions 里勾选 **draft**。虚拟机同时留着上一块 OpenCore 盘；新盘失败就改回旧盘，不要先删。

6. **最少要测这三条**

   - OpenCanopy 菜单能出来
   - 已安装的 macOS 能进桌面
   - 你如果用恢复/安装器，两条路都还在

7. **通过后再改钉住的版本并正式发版**

   编辑 `scripts/component-versions.env`，提交，再 Run workflow（不要开 `use_latest` 当常规升级）。
   同一 tag 重打用 **overwrite**。

8. **契约本身变了才改 `kvm-compat.json`**

   那是有意修改 KVM 行为，必须在文档 / review 里写原因，不能为了让检查变绿就改契约。

## 发版（已经升级评估过之后）

GitHub → **Actions → Release → Run workflow**：

- `release_version`：例如 `v23`
- `opencore_version`：具体 tag，例如 `1.0.7`。常规升级不要填 `latest`
- 同一 tag 重打：打开 **overwrite**

也可以：

```bash
git tag v23
git push origin v23
```

本地（不需要 Xcode）：

```bash
make review          # 看当前 pin → 上游 latest
make check           # KVM 契约
./scripts/package-release.sh --version v23 --opencore 1.0.7
```

macOS 上从 submodule 源码编译仍是 `make` / `make dist RELEASE_VERSION=v23`。源码构建**同样**要先 `make review` 和 `make check`。

## 虚拟机侧注意

- 本仓库工作流打出来的是真正的光盘。Proxmox：把 `OpenCore-<tag>.iso` 传到 ISO 存储，按 CD-ROM 挂上即可。QEMU：`-cdrom OpenCore-<tag>.iso`。不要当成硬盘导入。
- 创建虚拟机时 **OS Type 选 Other**。USB 3 直通要靠这一项，它不是 OpenCore 的 plist 键。详见 [docs/hardware.zh-CN.md](docs/hardware.zh-CN.md)。
- thenickdude 的旧版（`OpenCore-v21.iso` 及更早）仍是 GPT 磁盘改了扩展名，那些还是要按硬盘挂。
- 固件用原版 OVMF 即可，不必再打补丁。
- `libvirt.xml` 默认仍是 Penryn。较新的 Intel 宿主要用 `host-passthrough` 才更强，但必须在**自己的** config 里清掉 Penryn 的 `Cpuid1Data` 伪装。12 代及更新的大小核往往只能绑 P 核，或改用 Skylake-Client 这类具名型号。见 [docs/hardware.zh-CN.md](docs/hardware.zh-CN.md)。
- RX 6600 XT 等 Navi：自己加 `agdpmod=pikera`。共用 ISO 不加（会搞坏 Polaris）。

## 感谢

没有下面这些项目，就不会有这个克隆仓库：

- [Leoyzen/KVM-Opencore](https://github.com/leoyzen/KVM-Opencore) — 最初的 QEMU/KVM OpenCore 镜像，以及 ACPI / libvirt 布局。
- [thenickdude/KVM-Opencore](https://github.com/thenickdude/KVM-Opencore) — 本仓库的来源：构建系统、发行编号，以及现在仍在用的 QEMU/KVM `config.plist`。
- [LongQT-sea/OpenCore-ISO](https://github.com/LongQT-sea/OpenCore-ISO) 与 [qemu-cpu-guide](https://github.com/LongQT-sea/qemu-cpu-guide) — 真正的 CD-ROM ISO、Proxmox 用法，以及 Skylake 和 `host` 怎么选。
- [acidanthera](https://github.com/acidanthera) — OpenCore、Lilu、WhateverGreen 等官方 RELEASE。
- [Dortania](https://dortania.github.io/) — OpenCore 安装指南和显卡购买指南（含 Navi / `agdpmod=pikera`）。
- [kholia/OSX-KVM](https://github.com/kholia/OSX-KVM) — QEMU USB/xHCI（`msi=off`）写法。
- [Nick Sherlock](https://www.nicksherlock.com/) — Proxmox 上的 macOS 教程（OS Type Other、`ProvideCurrentCpuInfo`、USB 3）。
