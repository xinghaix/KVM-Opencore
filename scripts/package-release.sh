#!/usr/bin/env bash
# Assemble a KVM-Opencore release from official acidanthera binaries
# plus this repo's config.plist, ACPI, and custom kexts.
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
IMAGE_MB="${IMAGE_MB:-150}"
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
VERSIONS_OUT="${OUT_DIR}/versions.txt"
SUMS="${OUT_DIR}/SHA256SUMS"
PDF="${OUT_DIR}/Configuration.pdf"

rm -f "${ISO}" "${ISO}.gz" "${ZIP}" "${NOTES}" "${VERSIONS_OUT}" "${SUMS}" "${PDF}"
cp -a "${OC_EXTRACT}/Docs/Configuration.pdf" "${PDF}"

(
  cd "${STAGE}"
  zip -q -X -r "${ZIP}" EFI
)

create_image_macos() {
  local img="$1"
  rm -f "${img}" "${img}.cdr"
  # -srcfolder copies EFI/ into the image without mounting a FAT volume.
  hdiutil create \
    -ov \
    -srcfolder "${STAGE}" \
    -layout GPTSPUD \
    -fs "MS-DOS FAT32" \
    -volname EFI \
    -format UDTO \
    -size "${IMAGE_MB}m" \
    "${img}" >/dev/null
  if [[ -f "${img}.cdr" ]]; then
    mv "${img}.cdr" "${img}"
  fi
  mark_partition_efi "${img}"
}

mark_partition_efi() {
  python3 - "$1" <<'PY'
import struct, sys, uuid, zlib, pathlib

def crc32(blob: bytes) -> int:
    return zlib.crc32(blob) & 0xFFFFFFFF

def patch_header(buf: bytearray, header_off: int, array: bytes) -> None:
    header_size = struct.unpack_from("<I", buf, header_off + 12)[0]
    struct.pack_into("<I", buf, header_off + 88, crc32(array))
    struct.pack_into("<I", buf, header_off + 16, 0)
    struct.pack_into("<I", buf, header_off + 16, crc32(bytes(buf[header_off:header_off + header_size])))

path = pathlib.Path(sys.argv[1])
data = bytearray(path.read_bytes())
if data[512:520] != b"EFI PART":
    raise SystemExit(f"{path} is not a GPT disk image")

entry_lba, = struct.unpack_from("<Q", data, 512 + 72)
num_parts, entry_size = struct.unpack_from("<II", data, 512 + 80)
alt_lba, = struct.unpack_from("<Q", data, 512 + 32)
array_off = entry_lba * 512
array_len = num_parts * entry_size
efi_type = uuid.UUID("C12A7328-F81F-11D2-BA4B-00A0C93EC93B").bytes_le
data[array_off:array_off + 16] = efi_type
data[array_off + 56:array_off + 128] = "EFI".encode("utf-16le").ljust(72, b"\x00")

backup_array_off = (alt_lba * 512) - array_len
if 0 < backup_array_off < len(data):
    data[backup_array_off:backup_array_off + 16] = efi_type
    data[backup_array_off + 56:backup_array_off + 128] = "EFI".encode("utf-16le").ljust(72, b"\x00")

array = bytes(data[array_off:array_off + array_len])
patch_header(data, 512, array)
if backup_array_off > 0:
    patch_header(data, alt_lba * 512, bytes(data[backup_array_off:backup_array_off + array_len]))

path.write_bytes(data)
PY
}

create_image_linux() {
  local img="$1"
  need sgdisk
  need mkfs.vfat
  need mcopy
  local fat="${WORK_DIR}/efi-fat.img"
  rm -f "${fat}"
  truncate -s "${IMAGE_MB}M" "${img}"
  sgdisk --zap-all "${img}" >/dev/null
  sgdisk --new=1:40:0 --typecode=1:ef00 --change-name=1:EFI "${img}" >/dev/null
  local start end sectors
  start="$(sgdisk -i 1 "${img}" | awk '/First sector:/{print $3}')"
  end="$(sgdisk -i 1 "${img}" | awk '/Last sector:/{print $3}')"
  sectors="$((end - start + 1))"
  truncate -s "$((sectors * 512))" "${fat}"
  mkfs.vfat -F 32 -n EFI "${fat}" >/dev/null
  export MTOOLS_SKIP_CHECK=1
  mcopy -i "${fat}" -s "${EFI}" ::
  dd if="${fat}" of="${img}" bs=512 seek="${start}" conv=notrunc status=none
  rm -f "${fat}"
  mark_partition_efi "${img}"
}

case "$(uname -s)" in
  Darwin) create_image_macos "${ISO}" ;;
  Linux) create_image_linux "${ISO}" ;;
  *) echo "unsupported OS for disk image: $(uname -s)" >&2; exit 1 ;;
esac

gzip -f --keep "${ISO}"

cat > "${VERSIONS_OUT}" <<EOF
RELEASE_VERSION=${RELEASE_VERSION}
OPENCORE_VERSION=${OPENCORE_VERSION}
LILU_VERSION=${LILU_VERSION}
WHATEVERGREEN_VERSION=${WHATEVERGREEN_VERSION}
VIRTUALSMC_VERSION=${VIRTUALSMC_VERSION}
APPLEALC_VERSION=${APPLEALC_VERSION}
BRCMPATCHRAM_VERSION=${BRCMPATCHRAM_VERSION}
CRYPTEXFIXUP_VERSION=${CRYPTEXFIXUP_VERSION}
EOF

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
  echo "- \`OpenCore-${RELEASE_VERSION}.iso.gz\` — GPT+FAT32 disk image with a \`.iso\` name so Proxmox lists it. Attach it as a disk, not as a real optical ISO."
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
    sha256sum "OpenCore-${RELEASE_VERSION}.iso.gz" "OpenCoreEFIFolder-${RELEASE_VERSION}.zip" Configuration.pdf upgrade-review.md > SHA256SUMS
  else
    shasum -a 256 "OpenCore-${RELEASE_VERSION}.iso.gz" "OpenCoreEFIFolder-${RELEASE_VERSION}.zip" Configuration.pdf upgrade-review.md > SHA256SUMS
  fi
)

echo "=== outputs ==="
ls -lh "${ISO}.gz" "${ZIP}" "${PDF}" "${VERSIONS_OUT}" "${SUMS}"
echo "done ${RELEASE_VERSION}"
