#!/usr/bin/env bash
# Assemble a KVM-Opencore release from official acidanthera binaries
# plus this repo's config.plist, ACPI, and custom kexts.
# The .iso is a real ISO 9660 + UEFI El Torito image for CD-ROM boot.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSIONS_FILE="${ROOT}/scripts/component-versions.env"
# shellcheck disable=SC1090
[[ -f "${VERSIONS_FILE}" ]] && source "${VERSIONS_FILE}"

RELEASE_VERSION="${RELEASE_VERSION:-}"
OPENCORE_VERSION="${OPENCORE_VERSION:-1.0.7}"
LILU_VERSION="${LILU_VERSION:-latest}"
WHATEVERGREEN_VERSION="${WHATEVERGREEN_VERSION:-latest}"
VIRTUALSMC_VERSION="${VIRTUALSMC_VERSION:-latest}"
APPLEALC_VERSION="${APPLEALC_VERSION:-latest}"
BRCMPATCHRAM_VERSION="${BRCMPATCHRAM_VERSION:-latest}"
CRYPTEXFIXUP_VERSION="${CRYPTEXFIXUP_VERSION:-latest}"
WORK_DIR="${WORK_DIR:-${ROOT}/build}"
OUT_DIR="${OUT_DIR:-${ROOT}/dist}"
# Keep the El Torito EFI image below 32 MiB. Some OVMF versions treat a
# 32 MiB image's 16-bit sector count (0xffff/0) as an invalid boot image.
ELTORITO_MIN_MB="${ELTORITO_MIN_MB:-24}"
ELTORITO_MAX_MB="${ELTORITO_MAX_MB:-31}"
USE_LATEST="${USE_LATEST:-false}"
PINNED_OPENCORE="${OPENCORE_VERSION}"

usage() {
  cat <<'EOF'
Usage: package-release.sh [options]

  --version NAME          Release name used in filenames (e.g. v22)
  --opencore TAG          OpenCorePkg release tag or "latest"
  --use-latest            Resolve every component to its latest GitHub release
                          (still requires the KVM contract check to pass)
  --work-dir DIR          Scratch directory (default: ./build)
  --out-dir DIR           Output directory (default: ./dist)
  -h, --help              Show this help

Environment variables of the same names (RELEASE_VERSION, OPENCORE_VERSION,
LILU_VERSION, ...) also work. Component pins live in
scripts/component-versions.env.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) RELEASE_VERSION="$2"; shift 2 ;;
    --opencore) OPENCORE_VERSION="$2"; shift 2 ;;
    --use-latest) USE_LATEST=true; shift ;;
    --work-dir) WORK_DIR="$2"; shift 2 ;;
    --out-dir) OUT_DIR="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

need curl
need unzip
need zip
need python3
need git

DOWNLOADS="${WORK_DIR}/downloads"
STAGE="${WORK_DIR}/stage"
EFI="${STAGE}/EFI"

mkdir -p "${DOWNLOADS}" "${STAGE}" "${OUT_DIR}"
rm -rf "${EFI}"
mkdir -p "${EFI}"

github_headers_py() {
  cat <<'PY'
import os
def headers():
    h = {"User-Agent": "KVM-Opencore-packager", "Accept": "application/vnd.github+json"}
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if token:
        h["Authorization"] = f"Bearer {token}"
    return h
PY
}

latest_tag() {
  local repo="$1"
  python3 - "$repo" <<PY
$(github_headers_py)
import json, sys, urllib.request
repo = sys.argv[1]
url = f"https://api.github.com/repos/{repo}/releases/latest"
req = urllib.request.Request(url, headers=headers())
with urllib.request.urlopen(req) as resp:
    data = json.load(resp)
print(data["tag_name"])
PY
}

resolve_tag() {
  local repo="$1" requested="$2"
  if [[ "${USE_LATEST}" == "true" || "${requested}" == "latest" ]]; then
    latest_tag "${repo}"
  else
    printf '%s\n' "${requested}"
  fi
}

download_asset() {
  local repo="$1" tag="$2" pattern="$3" dest="$4"
  local api url
  api="https://api.github.com/repos/${repo}/releases/tags/${tag}"
  url="$(python3 - "$api" "$pattern" <<PY
$(github_headers_py)
import json, sys, urllib.request, fnmatch
api, pattern = sys.argv[1], sys.argv[2]
req = urllib.request.Request(api, headers=headers())
with urllib.request.urlopen(req) as resp:
    data = json.load(resp)
for asset in data.get("assets", []):
    name = asset["name"]
    if fnmatch.fnmatch(name, pattern):
        print(asset["browser_download_url"])
        break
else:
    raise SystemExit(f"no asset matching {pattern!r} in {api}")
PY
)"
  if [[ -s "${dest}" ]]; then
    echo "reusing ${dest}"
    return 0
  fi
  echo "downloading ${repo}@${tag} -> ${dest}"
  curl -fsSL --retry 3 --retry-delay 2 -o "${dest}" "${url}"
}

copy_kext() {
  local src="$1" name="$2"
  local dest="${EFI}/OC/Kexts/${name}"
  rm -rf "${dest}"
  mkdir -p "${EFI}/OC/Kexts"
  cp -a "${src}" "${dest}"
  find "${dest}" -name '.DS_Store' -delete
  # Drop debug symbols if a release zip shipped them next to the kext.
  rm -rf "${dest}.dSYM"
}

OPENCORE_VERSION="$(resolve_tag acidanthera/OpenCorePkg "${OPENCORE_VERSION}")"
LILU_VERSION="$(resolve_tag acidanthera/Lilu "${LILU_VERSION}")"
WHATEVERGREEN_VERSION="$(resolve_tag acidanthera/WhateverGreen "${WHATEVERGREEN_VERSION}")"
VIRTUALSMC_VERSION="$(resolve_tag acidanthera/VirtualSMC "${VIRTUALSMC_VERSION}")"
APPLEALC_VERSION="$(resolve_tag acidanthera/AppleALC "${APPLEALC_VERSION}")"
BRCMPATCHRAM_VERSION="$(resolve_tag acidanthera/BrcmPatchRAM "${BRCMPATCHRAM_VERSION}")"
CRYPTEXFIXUP_VERSION="$(resolve_tag acidanthera/CryptexFixup "${CRYPTEXFIXUP_VERSION}")"

if [[ -z "${RELEASE_VERSION}" ]]; then
  RELEASE_VERSION="oc-${OPENCORE_VERSION}"
fi

echo "=== packaging ${RELEASE_VERSION} ==="
echo "OpenCore      ${OPENCORE_VERSION}"
echo "Lilu          ${LILU_VERSION}"
echo "WhateverGreen ${WHATEVERGREEN_VERSION}"
echo "VirtualSMC    ${VIRTUALSMC_VERSION}"
echo "AppleALC      ${APPLEALC_VERSION}"
echo "BrcmPatchRAM  ${BRCMPATCHRAM_VERSION}"
echo "CryptexFixup  ${CRYPTEXFIXUP_VERSION}"

OC_ZIP="${DOWNLOADS}/OpenCore-${OPENCORE_VERSION}-RELEASE.zip"
download_asset acidanthera/OpenCorePkg "${OPENCORE_VERSION}" "OpenCore-*-RELEASE.zip" "${OC_ZIP}"
download_asset acidanthera/Lilu "${LILU_VERSION}" "Lilu-*-RELEASE.zip" "${DOWNLOADS}/Lilu-${LILU_VERSION}-RELEASE.zip"
download_asset acidanthera/WhateverGreen "${WHATEVERGREEN_VERSION}" "WhateverGreen-*-RELEASE.zip" "${DOWNLOADS}/WhateverGreen-${WHATEVERGREEN_VERSION}-RELEASE.zip"
download_asset acidanthera/VirtualSMC "${VIRTUALSMC_VERSION}" "VirtualSMC-*-RELEASE.zip" "${DOWNLOADS}/VirtualSMC-${VIRTUALSMC_VERSION}-RELEASE.zip"
download_asset acidanthera/AppleALC "${APPLEALC_VERSION}" "AppleALC-*-RELEASE.zip" "${DOWNLOADS}/AppleALC-${APPLEALC_VERSION}-RELEASE.zip"
download_asset acidanthera/BrcmPatchRAM "${BRCMPATCHRAM_VERSION}" "BrcmPatchRAM-*-RELEASE.zip" "${DOWNLOADS}/BrcmPatchRAM-${BRCMPATCHRAM_VERSION}-RELEASE.zip"
download_asset acidanthera/CryptexFixup "${CRYPTEXFIXUP_VERSION}" "CryptexFixup-*-RELEASE.zip" "${DOWNLOADS}/CryptexFixup-${CRYPTEXFIXUP_VERSION}-RELEASE.zip"

OC_EXTRACT="${WORK_DIR}/opencore"
rm -rf "${OC_EXTRACT}"
mkdir -p "${OC_EXTRACT}"
unzip -q -o "${OC_ZIP}" -d "${OC_EXTRACT}"

# Start from this repo's EFI (config, ACPI, custom kexts), then overlay binaries.
cp -a "${ROOT}/EFI" "${STAGE}/"
find "${EFI}" -name '.DS_Store' -delete

mkdir -p "${EFI}/BOOT" "${EFI}/OC/Drivers" "${EFI}/OC/Tools" "${EFI}/OC/Kexts"
cp -a "${OC_EXTRACT}/X64/EFI/BOOT/BOOTx64.efi" "${EFI}/BOOT/BOOTx64.efi"
cp -a "${OC_EXTRACT}/X64/EFI/OC/OpenCore.efi" "${EFI}/OC/OpenCore.efi"
for driver in OpenRuntime.efi OpenHfsPlus.efi OpenCanopy.efi OpenPartitionDxe.efi ResetNvramEntry.efi ToggleSipEntry.efi; do
  cp -a "${OC_EXTRACT}/X64/EFI/OC/Drivers/${driver}" "${EFI}/OC/Drivers/${driver}"
done
cp -a "${OC_EXTRACT}/X64/EFI/OC/Tools/OpenShell.efi" "${EFI}/OC/Tools/Shell.efi"
cp -a "${OC_EXTRACT}/X64/EFI/OC/Tools/ResetSystem.efi" "${EFI}/OC/Tools/ResetSystem.efi"

extract_zip() {
  local zip="$1" dest="$2"
  rm -rf "${dest}"
  mkdir -p "${dest}"
  unzip -q -o "${zip}" -d "${dest}"
}

KEXTS_TMP="${WORK_DIR}/kexts"
extract_zip "${DOWNLOADS}/Lilu-${LILU_VERSION}-RELEASE.zip" "${KEXTS_TMP}/Lilu"
extract_zip "${DOWNLOADS}/WhateverGreen-${WHATEVERGREEN_VERSION}-RELEASE.zip" "${KEXTS_TMP}/WhateverGreen"
extract_zip "${DOWNLOADS}/VirtualSMC-${VIRTUALSMC_VERSION}-RELEASE.zip" "${KEXTS_TMP}/VirtualSMC"
extract_zip "${DOWNLOADS}/AppleALC-${APPLEALC_VERSION}-RELEASE.zip" "${KEXTS_TMP}/AppleALC"
extract_zip "${DOWNLOADS}/BrcmPatchRAM-${BRCMPATCHRAM_VERSION}-RELEASE.zip" "${KEXTS_TMP}/BrcmPatchRAM"
extract_zip "${DOWNLOADS}/CryptexFixup-${CRYPTEXFIXUP_VERSION}-RELEASE.zip" "${KEXTS_TMP}/CryptexFixup"

copy_kext "${KEXTS_TMP}/Lilu/Lilu.kext" Lilu.kext
copy_kext "${KEXTS_TMP}/WhateverGreen/WhateverGreen.kext" WhateverGreen.kext
copy_kext "${KEXTS_TMP}/AppleALC/AppleALC.kext" AppleALC.kext
copy_kext "${KEXTS_TMP}/CryptexFixup/CryptexFixup.kext" CryptexFixup.kext

if [[ -d "${KEXTS_TMP}/VirtualSMC/Kexts/VirtualSMC.kext" ]]; then
  copy_kext "${KEXTS_TMP}/VirtualSMC/Kexts/VirtualSMC.kext" VirtualSMC.kext
else
  copy_kext "${KEXTS_TMP}/VirtualSMC/VirtualSMC.kext" VirtualSMC.kext
fi

for kext in BrcmNonPatchRAM2.kext BrcmPatchRAM2.kext BrcmPatchRAM3.kext BrcmBluetoothInjector.kext BlueToolFixup.kext BrcmFirmwareData.kext; do
  copy_kext "${KEXTS_TMP}/BrcmPatchRAM/${kext}" "${kext}"
done

if [[ ! -d "${WORK_DIR}/OcBinaryData/.git" ]]; then
  rm -rf "${WORK_DIR}/OcBinaryData"
  git clone --depth 1 https://github.com/acidanthera/OcBinaryData.git "${WORK_DIR}/OcBinaryData"
else
  git -C "${WORK_DIR}/OcBinaryData" fetch --depth 1 origin master
  git -C "${WORK_DIR}/OcBinaryData" reset --hard origin/master
fi
rm -rf "${EFI}/OC/Resources"
cp -a "${WORK_DIR}/OcBinaryData/Resources" "${EFI}/OC/Resources"
find "${EFI}/OC/Resources" -name '.DS_Store' -delete

python3 "${ROOT}/scripts/ensure_oc_config.py" \
  "${EFI}/OC/config.plist" \
  --sample "${OC_EXTRACT}/Docs/Sample.plist" \
  --in-place

if command -v plutil >/dev/null 2>&1; then
  plutil -convert xml1 "${EFI}/OC/config.plist"
fi

OCVALIDATE=""
case "$(uname -s)" in
  Linux) OCVALIDATE="${OC_EXTRACT}/Utilities/ocvalidate/ocvalidate.linux" ;;
  Darwin) OCVALIDATE="${OC_EXTRACT}/Utilities/ocvalidate/ocvalidate" ;;
esac
if [[ -n "${OCVALIDATE}" && -f "${OCVALIDATE}" ]]; then
  chmod +x "${OCVALIDATE}"
  echo "=== ocvalidate ==="
  "${OCVALIDATE}" "${EFI}/OC/config.plist"
fi

echo "=== KVM compatibility contract ==="
python3 "${ROOT}/scripts/check-kvm-compat.py" "${EFI}/OC/config.plist" --efi-root "${EFI}"

echo "=== upgrade review ${PINNED_OPENCORE} -> ${OPENCORE_VERSION} ==="
python3 "${ROOT}/scripts/review-upgrade.py" \
  --from "${PINNED_OPENCORE}" \
  --to "${OPENCORE_VERSION}" \
  --config "${ROOT}/EFI/OC/config.plist" \
  --sample "${OC_EXTRACT}/Docs/Sample.plist" \
  --changelog "${OC_EXTRACT}/Docs/Changelog.md" \
  --output "${OUT_DIR}/upgrade-review.md"

required=(
  "${EFI}/BOOT/BOOTx64.efi"
  "${EFI}/OC/OpenCore.efi"
  "${EFI}/OC/config.plist"
  "${EFI}/OC/Drivers/OpenRuntime.efi"
  "${EFI}/OC/Drivers/OpenHfsPlus.efi"
  "${EFI}/OC/Drivers/OpenCanopy.efi"
  "${EFI}/OC/Tools/Shell.efi"
  "${EFI}/OC/Kexts/Lilu.kext/Contents/MacOS/Lilu"
  "${EFI}/OC/Kexts/WhateverGreen.kext/Contents/MacOS/WhateverGreen"
  "${EFI}/OC/Kexts/AppleALC.kext/Contents/MacOS/AppleALC"
  "${EFI}/OC/Kexts/VirtualSMC.kext/Contents/MacOS/VirtualSMC"
  "${EFI}/OC/Kexts/CryptexFixup.kext/Contents/MacOS/CryptexFixup"
  "${EFI}/OC/Kexts/BlueToolFixup.kext/Contents/MacOS/BlueToolFixup"
  "${EFI}/OC/Kexts/USBPorts.kext/Contents/Info.plist"
  "${EFI}/OC/ACPI/SSDT-EC.aml"
  "${EFI}/OC/Resources/Image"
)
for path in "${required[@]}"; do
  [[ -e "${path}" ]] || { echo "missing required file: ${path}" >&2; exit 1; }
done

ISO="${OUT_DIR}/OpenCore-${RELEASE_VERSION}.iso"
ZIP="${OUT_DIR}/OpenCoreEFIFolder-${RELEASE_VERSION}.zip"
NOTES="${OUT_DIR}/release-notes.md"
SUMS="${OUT_DIR}/SHA256SUMS"
PDF="${OUT_DIR}/Configuration.pdf"

rm -f "${ISO}" "${ISO}.gz" "${ZIP}" "${NOTES}" "${SUMS}" "${PDF}" "${OUT_DIR}/versions.txt"
cp -a "${OC_EXTRACT}/Docs/Configuration.pdf" "${PDF}"

(
  cd "${STAGE}"
  zip -q -X -r "${ZIP}" EFI
)

create_fat_esp() {
  local fat="$1"
  local mb="$2"
  local mkfs=""
  local candidate
  for candidate in mkfs.vfat mkfs.fat \
      /opt/homebrew/sbin/mkfs.vfat /opt/homebrew/sbin/mkfs.fat \
      /usr/local/sbin/mkfs.vfat /usr/local/sbin/mkfs.fat \
      /usr/sbin/mkfs.vfat /usr/sbin/mkfs.fat; do
    if [[ "${candidate}" == /* ]]; then
      if [[ -x "${candidate}" ]]; then
        mkfs="${candidate}"
        break
      fi
    else
      mkfs="$(command -v "${candidate}" || true)"
      if [[ -n "${mkfs}" ]]; then
        break
      fi
    fi
  done
  [[ -n "${mkfs}" ]] || {
    echo "missing required command: mkfs.vfat or mkfs.fat" >&2
    exit 1
  }
  need mcopy
  rm -f "${fat}"
  truncate -s "${mb}M" "${fat}"
  # FAT16 matches the small ESP used by LongQT/OpenCore-ISO and avoids the
  # El Torito 16-bit sector-count boundary that breaks some OVMF builds.
  "${mkfs}" -F 16 -n OPENCORE "${fat}" >/dev/null
  export MTOOLS_SKIP_CHECK=1
  mcopy -i "${fat}" -s "${EFI}" ::
}

# Real ISO 9660 + El Torito UEFI so QEMU/Proxmox can attach it as a CD-ROM.
create_uefi_iso() {
  local iso="$1"
  need xorriso
  local fat="${WORK_DIR}/efiboot.img"
  local root="${WORK_DIR}/iso-root"
  local efi_kb mb
  efi_kb="$(du -sk "${EFI}" | awk '{print $1}')"
  # Leave filesystem/headroom space, but stay below 32 MiB so xorriso writes
  # a non-zero El Torito sector count that older OVMF versions accept.
  mb=$(( (efi_kb + 8192 + 1023) / 1024 ))
  if (( mb < ELTORITO_MIN_MB )); then mb="${ELTORITO_MIN_MB}"; fi
  if (( mb > ELTORITO_MAX_MB )); then
    echo "EFI tree is too large for a compatible El Torito ESP: ${efi_kb} KiB" >&2
    echo "Reduce EFI resources or raise the format design limit deliberately; do not use a 32 MiB image." >&2
    exit 1
  fi

  echo "building UEFI El Torito ISO (${mb} MiB FAT16 ESP)"
  create_fat_esp "${fat}" "${mb}"
  rm -rf "${root}"
  mkdir -p "${root}/EFI/BOOT"
  cp -a "${STAGE}/EFI" "${root}/"
  cp -a "${fat}" "${root}/EFI/BOOT/efiboot.img"

  rm -f "${iso}"
  xorriso -as mkisofs \
    -quiet \
    -iso-level 3 \
    -full-iso9660-filenames \
    -joliet \
    -joliet-long \
    -rational-rock \
    -volid "OPENCORE" \
    -eltorito-alt-boot \
    -e EFI/BOOT/efiboot.img \
    -no-emul-boot \
    -isohybrid-gpt-basdat \
    -output "${iso}" \
    "${root}"

  python3 - "${iso}" <<'PY'
import pathlib
import struct
import sys

path = pathlib.Path(sys.argv[1])
data = path.read_bytes()
block = 2048
if len(data) < 19 * block or data[16 * block + 1:16 * block + 6] != b"CD001":
    raise SystemExit("output is not an ISO 9660 image")
boot_record = data[17 * block:(18 * block)]
if boot_record[1:6] != b"CD001" or boot_record[7:39].startswith(b"EL TORITO") is False:
    raise SystemExit("ISO has no El Torito boot record")
catalog_lba = struct.unpack_from("<I", boot_record, 71)[0]
catalog = data[catalog_lba * block:(catalog_lba + 1) * block]
if catalog[30:32] != b"\x55\xaa" or catalog[1] != 0xEF:
    raise SystemExit("El Torito catalog is not a UEFI catalog")
initial = catalog[32:64]
sector_count = struct.unpack_from("<H", initial, 6)[0]
boot_lba = struct.unpack_from("<I", initial, 8)[0]
if initial[0] != 0x88 or initial[1] != 0 or sector_count == 0 or boot_lba == 0:
    raise SystemExit(
        f"incompatible UEFI El Torito entry: indicator={initial[0]:#x}, "
        f"media={initial[1]:#x}, sectors={sector_count}, lba={boot_lba}"
    )
print(f"verified UEFI El Torito boot image: LBA {boot_lba}, {sector_count} sectors")
PY
}

create_uefi_iso "${ISO}"

gzip -f --keep "${ISO}"

{
  echo "# ${RELEASE_VERSION} — OpenCore ${OPENCORE_VERSION} for QEMU/KVM"
  echo
  echo "Assembled from official acidanthera RELEASE builds, plus this repository's"
  echo "QEMU/KVM \`config.plist\`, ACPI tables, and custom kexts."
  echo
  echo "| Component | Version |"
  echo "| --- | --- |"
  echo "| OpenCorePkg | ${OPENCORE_VERSION} |"
  echo "| Lilu | ${LILU_VERSION} |"
  echo "| WhateverGreen | ${WHATEVERGREEN_VERSION} |"
  echo "| VirtualSMC | ${VIRTUALSMC_VERSION} |"
  echo "| AppleALC | ${APPLEALC_VERSION} |"
  echo "| BrcmPatchRAM | ${BRCMPATCHRAM_VERSION} |"
  echo "| CryptexFixup | ${CRYPTEXFIXUP_VERSION} |"
  echo
  echo "## Assets"
  echo
  echo "- \`OpenCore-${RELEASE_VERSION}.iso\` — real ISO 9660 + UEFI El Torito image. Upload it to the ISO store and attach it as a CD-ROM. Do not convert it to a hard disk."
  echo "- \`OpenCore-${RELEASE_VERSION}.iso.gz\` — the same ISO, gzipped."
  echo "- \`OpenCoreEFIFolder-${RELEASE_VERSION}.zip\` — raw \`EFI/\` folder."
  echo "- \`Configuration.pdf\` — OpenCore ${OPENCORE_VERSION} manual."
  echo "- \`upgrade-review.md\` — changelog between the previously pinned OpenCore and this build. Read it before replacing a working VM disk."
  echo
  echo "This image keeps the QEMU/KVM contract in \`scripts/kvm-compat.json\`. Do not copy Sample.plist over \`EFI/OC/config.plist\`."
  echo
  echo "Rebuild locally with \`./scripts/package-release.sh --version ${RELEASE_VERSION} --opencore ${OPENCORE_VERSION}\`."
} > "${NOTES}"

(
  cd "${OUT_DIR}"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "OpenCore-${RELEASE_VERSION}.iso" "OpenCore-${RELEASE_VERSION}.iso.gz" "OpenCoreEFIFolder-${RELEASE_VERSION}.zip" Configuration.pdf upgrade-review.md > SHA256SUMS
  else
    shasum -a 256 "OpenCore-${RELEASE_VERSION}.iso" "OpenCore-${RELEASE_VERSION}.iso.gz" "OpenCoreEFIFolder-${RELEASE_VERSION}.zip" Configuration.pdf upgrade-review.md > SHA256SUMS
  fi
)

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "release_version=${RELEASE_VERSION}"
    echo "opencore_version=${OPENCORE_VERSION}"
  } >> "${GITHUB_OUTPUT}"
fi

echo "=== outputs ==="
ls -lh "${ISO}" "${ISO}.gz" "${ZIP}" "${PDF}" "${SUMS}"
echo "done ${RELEASE_VERSION}"
