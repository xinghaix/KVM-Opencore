# KVM-Opencore

This is a fork of [Leoyzen's OpenCore image](https://github.com/leoyzen/KVM-Opencore) for QEMU/KVM, 
which I've extended to add a build system for automatically buliding all of the required files from 
sourcecode, and to keep up with the latest OpenCore changes.

This repository (`xinghaix/KVM-Opencore`) adds a GitHub Actions workflow that assembles
official [acidanthera](https://github.com/acidanthera) RELEASE builds (OpenCore 1.0.7 and matching
kexts by default) with this tree's QEMU/KVM `config.plist`, ACPI, and custom kexts, then publishes
GitHub Releases.

It is currently tested to boot macOS Catalina, Big Sur, and Monterey, but will likely also boot older 
versions of macOS.

Although the images offered here should work on all QEMU/KVM distributions, I specifically build
and test these for my Proxmox Hackintosh guide here:

https://www.nicksherlock.com/2021/10/installing-macos-12-monterey-on-proxmox-7/

Note that although the images in the Releases have filenames like OpenCore-v15.iso, these aren't 
real ISOs, but rather raw hard disk images, and need to be booted as such. (They're just using .iso
extensions so they'll appear in Proxmox's disk image picker).

## Automated releases

GitHub Actions packages images on this fork. It does **not** compile OpenCore from the git
submodules (that still needs macOS + Xcode and `make`). CI downloads the official RELEASE zips,
overlays `EFI/OC/config.plist` / ACPI / custom kexts, runs `ocvalidate`, and publishes:

- `OpenCore-<tag>.iso.gz` — GPT + FAT32 disk image (Proxmox "ISO" picker)
- `OpenCoreEFIFolder-<tag>.zip` — raw `EFI/` folder
- `Configuration.pdf`, `SHA256SUMS`, `versions.txt`

### Run a release on GitHub

1. Push this repository to your own GitHub account (a fork is fine).
2. Open **Actions → Release → Run workflow**.
3. Set **release_version** (for example `v22`) and **opencore_version** (`1.0.7` or `latest`).
4. The workflow creates a GitHub Release on *this* repository.

You can also push a tag:

```bash
git tag v22
git push origin v22
```

To rebuild the same tag, re-run the workflow with **overwrite** enabled.

### Package locally (no Xcode)

```bash
./scripts/package-release.sh --version v22 --opencore 1.0.7
```

Pins live in `scripts/component-versions.env`. Pass `--use-latest` to ignore them.

Source builds are unchanged: `make` and `make dist RELEASE_VERSION=v22` on macOS.
