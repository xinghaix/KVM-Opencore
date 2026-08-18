# KVM-Opencore

[中文](#中文) · [English](#english)

QEMU/KVM 专用的 OpenCore 镜像。官方 OpenCore 只保证真机/Hackintosh，本仓库把 **QEMU + OVMF + q35** 上不能乱改的引导项写成契约，升级时必须先对照变更再打包。

OpenCore images for QEMU/KVM. Upstream OpenCore targets real Macs and Hackintoshes. This tree freezes the QEMU + OVMF + q35 settings that keep a guest booting, and refuses to ship an upgrade until that contract still holds.

Fork of [Leoyzen/KVM-Opencore](https://github.com/leoyzen/KVM-Opencore), with the source build system from [thenickdude/KVM-Opencore](https://github.com/thenickdude/KVM-Opencore). Automated releases live on [xinghaix/KVM-Opencore](https://github.com/xinghaix/KVM-Opencore).

---

## 中文

### 这是什么

GitHub Actions 下载 [acidanthera](https://github.com/acidanthera) 的官方 RELEASE 包，叠上本仓库的 `EFI/OC/config.plist`、ACPI 和自定义 kext，用**同一版本**的 `ocvalidate` 校验，再跑 `scripts/kvm-compat.json` 契约检查，最后发布：

- `OpenCore-<tag>.iso.gz` — GPT+FAT32 磁盘镜像（扩展名是 `.iso`，方便 Proxmox 选文件；**按硬盘挂，不要当光盘**）
- `OpenCoreEFIFolder-<tag>.zip` — 现成的 `EFI/`
- `upgrade-review.md` — **当前钉住的 OpenCore → 这次构建目标版本** 的官方 Changelog 摘录
- `Configuration.pdf` / `SHA256SUMS` / `versions.txt`

当前镜像按 Catalina / Big Sur / Monterey / Ventura 方向维护，更新的 macOS 需要先走下面的升级流程，不要假设能直接启动。

### 为什么不能只换核心

`package-release.sh` 换的是官方二进制，**不会**自动理解 1.0.7 到 1.0.8 之间改了什么。新版可能：

- 新增 `config.plist` 键，缺了 `ocvalidate` 直接失败
- Sample 默认值对真机合适、对 KVM 是致命的（例如 `Vault=Secure`、`SecureBootModel=Default`、`SetupVirtualMap=true`、`ClearTaskSwitchBit=true`）
- 改 VirtIO / 引导设备 / SMBIOS / CPU 行为，虚拟机进不了系统
- kext 的 `MinKernel`/`MaxKernel` 写错会再次出现开机十几分钟（v21 修过的蓝牙问题）

所以升级是固定流程，不是“把 `opencore_version` 改成 latest 再点 Run workflow”。

### 升级必备流程（按顺序）

不要跳步。契约检查失败的包**不准发正式版**。

1. **看当前钉住的版本和上游最新版差了什么**

   ```bash
   python3 scripts/review-upgrade.py --to latest
   ```

   默认从 `scripts/component-versions.env` 的 `OPENCORE_VERSION` 比到官方最新 tag。  
   先读输出里所有 **`[KVM]`** 行，再打开官方 [Changelog](https://github.com/acidanthera/OpenCorePkg/blob/master/Docs/Changelog.md) 和 [Differences](https://dortania.github.io/OpenCore-Install-Guide/differences.html)。

2. **只补 schema，禁止整份粘贴 Sample.plist**

   用 `scripts/ensure_oc_config.py` 补缺失键。KVM 相关值必须以本仓库为准，不要用 Sample 的默认值覆盖。  
   改完后把新键提交进 `EFI/OC/config.plist`，不要只存在于打包临时目录。

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

   那是有意修改 KVM 行为，必须在 README / review 里写原因，不能为了让检查变绿就改契约。

### 发版（已经升级评估过之后）

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

### 虚拟机侧注意

- 镜像是磁盘，不是 ISO9660 光盘。  
- 固件用原版 OVMF 即可，不必再打补丁。  
- CPU 用 `host-passthrough` 或 Penryn；`ProvideCurrentCpuInfo=true` 后不再强制 `+invtsc`。  
- 参考 `libvirt.xml`。

---

## English

### What this is

GitHub Actions downloads official [acidanthera](https://github.com/acidanthera) RELEASE zips, overlays this tree's QEMU/KVM `config.plist`, ACPI, and custom kexts, runs the **matching** `ocvalidate`, then enforces `scripts/kvm-compat.json` before publishing.

Release assets are the disk image, the `EFI/` zip, and `upgrade-review.md` (official changelog from the pinned OpenCore version to the version in that build).

The `.iso` name is only so Proxmox lists the file. It is a GPT+FAT32 disk image. Attach it as a disk.

Tested direction: Catalina, Big Sur, Monterey, Ventura. Newer macOS is not implied.

### Why a binary bump is not an upgrade

The packager does not understand the semantic delta between OpenCore releases. A newer core can add required plist keys, ship Sample defaults that brick KVM (`Vault=Secure`, `SecureBootModel=Default`, `SetupVirtualMap=true`), change VirtIO/boot-device/CPU behaviour, or reload the Bluetooth kexts that caused 20-minute boots in v20.

### Required upgrade process

Do these in order. A failed contract check must not be published.

1. **Read the delta**

   ```bash
   python3 scripts/review-upgrade.py --to latest
   ```

   Compare `scripts/component-versions.env` to the latest official tag. Read every **`[KVM]`** line, then the official changelog and [Dortania differences](https://dortania.github.io/OpenCore-Install-Guide/differences.html).

2. **Fill schema only. Never paste Sample.plist over this config.**

   `scripts/ensure_oc_config.py` adds missing keys. KVM contract values stay. Commit the filled keys to `EFI/OC/config.plist`.

3. **Run the contract check**

   ```bash
   python3 scripts/check-kvm-compat.py EFI/OC/config.plist
   make check
   ```

   The table in the Chinese section is the same contract. Highlights: `DummyPowerManagement`, `ProvideCurrentCpuInfo`, `SetApfsTrimTimeout=0`, `SetupVirtualMap=false`, `SecureBootModel=Disabled`, `Vault=Optional`, `Timeout=0`, Penryn CPUID, Bluetooth `MinKernel`/`MaxKernel` ranges, VirtualSMC left **disabled**.

4. **Validate with the target `ocvalidate`**, never an older configurator.

5. **Ship a draft and keep the previous OpenCore disk** for rollback.

   ```bash
   ./scripts/package-release.sh --version v23 --opencore 1.0.8
   ```

6. **Smoke-test** picker, installed macOS, and Recovery/installer if you use them.

7. **Then** bump `scripts/component-versions.env` and publish. Do not use `use_latest` as the normal upgrade path.

8. **Change `scripts/kvm-compat.json` only when the KVM behaviour is intentionally changing.** Document why.

### Publishing (after the review)

Actions → **Release** → Run workflow. Prefer an explicit `opencore_version` tag. Re-run with **overwrite** to replace the same tag.

```bash
make review
make check
./scripts/package-release.sh --version v23 --opencore 1.0.7
```

Source builds on macOS remain `make` / `make dist RELEASE_VERSION=v23`. Run `make review` and `make check` first.

### VM notes

Attach the image as a disk, not an optical ISO. Stock OVMF is enough. Use `host-passthrough` or Penryn; `+invtsc` is no longer required. See `libvirt.xml`.
