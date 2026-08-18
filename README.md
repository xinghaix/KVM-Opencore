# KVM-Opencore

**Language:** [中文](README.zh-CN.md) · English

OpenCore images for QEMU/KVM. Upstream OpenCore targets real Macs and Hackintoshes. This tree freezes the QEMU + OVMF + q35 settings that keep a guest booting, and refuses to ship an upgrade until that contract still holds.

This repository is a **clone** of [thenickdude/KVM-Opencore](https://github.com/thenickdude/KVM-Opencore) (which itself continues [Leoyzen/KVM-Opencore](https://github.com/leoyzen/KVM-Opencore)). It is not a new upstream project. The local additions are custom QEMU/KVM configuration, an automated release workflow, and the upgrade/compatibility checks described below.

## What this is

GitHub Actions downloads official [acidanthera](https://github.com/acidanthera) RELEASE zips, overlays this tree's QEMU/KVM `config.plist`, ACPI, and custom kexts, runs the **matching** `ocvalidate`, then enforces `scripts/kvm-compat.json` before publishing:

- `OpenCore-<tag>.iso` — real ISO 9660 + UEFI El Torito image. Upload it to the ISO store and attach it as a **CD-ROM**. No disk conversion.
- `OpenCore-<tag>.iso.gz` — the same ISO, gzipped
- `OpenCoreEFIFolder-<tag>.zip` — raw `EFI/` folder
- `upgrade-review.md` — official changelog excerpt from the **pinned OpenCore version to the version in this build**
- `Configuration.pdf` / `SHA256SUMS`

Maintained for Catalina / Big Sur / Monterey / Ventura. Newer macOS is not implied; follow the upgrade process below first.

## Why a binary bump is not an upgrade

`package-release.sh` swaps official binaries. It does **not** understand the semantic delta between 1.0.7 and 1.0.8. A newer core can:

- Add required `config.plist` keys; missing ones fail `ocvalidate`
- **Change recommended values** for keys we already have — sometimes faster, sometimes a brick
- Ship Sample defaults that are fine on real Macs and fatal on KVM (`Vault=Secure`, `SecureBootModel=Default`, `SetupVirtualMap=true`, `ClearTaskSwitchBit=true`)
- Change VirtIO / boot-device / SMBIOS / CPU behaviour so the guest will not boot
- Reload Bluetooth kexts with the wrong `MinKernel`/`MaxKernel` and bring back the 20-minute boots fixed in v21

So an upgrade is a fixed process. It is not “set `opencore_version` to latest and click Run workflow”, and it is also **not** locking every old value forever and missing official fixes.

## New keys and changed recommended values

`review-upgrade.py` compares the target `Sample.plist` and classifies every delta. The packager **never** overwrites an existing value.

| Class | What to do |
| --- | --- |
| **New keys** | Pick a KVM default and commit it to `EFI/OC/config.plist`. Sample is only a hint. If Sample is unsafe, lock our value in `scripts/kvm-compat.json`. |
| **Locked keys** | Do not follow Sample. Examples: `DummyPowerManagement=true`, `SetupVirtualMap=false`, `Vault=Optional`. Edit the contract only when KVM policy itself changes. |
| **Unlocked value changes** | These are the performance/bugfix candidates. Read the changelog, patch `config.plist`, test with the old disk still attached, commit only if it helps. |

Examples versus OpenCore 1.0.7 Sample:

- Candidate: `FixupAppleEfiImages` is `false` here and `true` upstream (boots newer/broken Apple EFI images). Evaluate it before a new macOS install.
- Do not follow Sample: `SetupVirtualMap`, `SecureBootModel`, `Vault`, `Timeout`, `DummyPowerManagement`.
- Not performance knobs: MLB / ROM / serial / UUID.

## Required upgrade process

Do these in order. A failed contract check must not be published.

1. **Read the delta**

   ```bash
   python3 scripts/review-upgrade.py --to latest
   ```

   This compares `OPENCORE_VERSION` in `scripts/component-versions.env` to the latest official tag.
   Read every **`[KVM]`** line and the three Sample-delta tables, then the official [Changelog](https://github.com/acidanthera/OpenCorePkg/blob/master/Docs/Changelog.md) and [Differences](https://dortania.github.io/OpenCore-Install-Guide/differences.html).

2. **Handle the three plist classes. Never paste Sample.plist over this config.**

   `scripts/ensure_oc_config.py` adds **missing** keys only.
   Then use the three tables from `review-upgrade.py`: commit new keys, keep locked values, evaluate candidate value changes one by one.
   Do not leave new keys only in the packager’s temp directory.

3. **Run the contract check**

   ```bash
   python3 scripts/check-kvm-compat.py EFI/OC/config.plist
   make check
   ```

   The contract lives in `scripts/kvm-compat.json` and at least includes:

   | Key | Required value | Why |
   | --- | --- | --- |
   | `DummyPowerManagement` | `true` | QEMU has no real SMC |
   | `ProvideCurrentCpuInfo` | `true` | host-passthrough / Penryn topology |
   | `SetApfsTrimTimeout` | `0` | TRIM on virtual disks is extremely slow at boot |
   | `SetupVirtualMap` | `false` | Breaks boot on many OVMF firmwares |
   | `ClearTaskSwitchBit` | `false` | Hyper-V only |
   | `SecureBootModel` | `Disabled` | Virtual SMBIOS is not a real Mac |
   | `Vault` | `Optional` | Sample `Secure` bricks this image |
   | `Timeout` | `0` | Non-zero can make the installer re-enter itself |
   | `SystemProductName` | `iMacPro1,1` | Default SMBIOS for this image |
   | `Cpuid1Data` | Penryn `54060500…` | Makes macOS accept the virtual CPU |
   | `BrcmBluetoothInjector` MaxKernel | `20.99.99` | Loading on Monterey+ caused 20-minute boots |
   | `VirtualSMC` | **disabled** | This image uses DummyPowerManagement |
   | `CryptexFixup` | enabled | Required for Ventura+ on hosts without AVX2 |

4. **Validate with the target `ocvalidate`**, never an older configurator.

   An old tool will not see new keys and will not enforce new rules.

5. **Ship a draft and keep the previous OpenCore disk** for rollback.

   ```bash
   ./scripts/package-release.sh --version v23 --opencore 1.0.8
   ```

   Or tick **draft** in Actions. Keep the previous OpenCore disk attached; switch back if the new one fails. Do not delete it first.

6. **Smoke-test at least these three**

   - OpenCanopy picker appears
   - Installed macOS reaches the desktop
   - Recovery/installer still works if you use them

7. **Then** bump `scripts/component-versions.env` and publish.

   Commit the pin, then Run workflow. Do not use `use_latest` as the normal upgrade path.
   Re-run with **overwrite** to replace the same tag.

8. **Change `scripts/kvm-compat.json` only when the KVM behaviour is intentionally changing.**

   Document why in the docs / review. Do not edit the contract just to make the check green.

## Publishing (after the review)

GitHub → **Actions → Release → Run workflow**:

- `release_version`: e.g. `v23`
- `opencore_version`: a concrete tag such as `1.0.7`. Do not use `latest` for a normal upgrade
- Re-run the same tag with **overwrite**

Or:

```bash
git tag v23
git push origin v23
```

Locally (no Xcode):

```bash
make review          # pinned core → upstream latest
make check           # KVM contract
./scripts/package-release.sh --version v23 --opencore 1.0.7
```

Source builds on macOS remain `make` / `make dist RELEASE_VERSION=v23`. Run `make review` and `make check` first.

## VM notes

- Releases from this workflow are real CDs. In Proxmox: upload `OpenCore-<tag>.iso` to the ISO storage and attach it as a CD-ROM. In QEMU: `-cdrom OpenCore-<tag>.iso`. Do not import it as a hard disk.
- Older thenickdude releases (`OpenCore-v21.iso` and earlier) were GPT disk images with an `.iso` name. Those still need to be attached as disks.
- Stock OVMF is enough; no patched firmware is required.
- Use `host-passthrough` or Penryn; `+invtsc` is no longer required once `ProvideCurrentCpuInfo=true`.
- See `libvirt.xml`.
