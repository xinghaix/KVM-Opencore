#!/usr/bin/env bash
# Install only the extra packages the Release job needs on ubuntu-24.04.
# GitHub-hosted runners often sit on this step because unattended-upgrades
# holds the dpkg lock, or because apt-get update has no HTTP timeout.
set -euo pipefail

need=(dosfstools mtools xorriso)
missing=()
for pkg in "${need[@]}"; do
  if dpkg-query -W -f='${Status}' "${pkg}" 2>/dev/null | grep -q 'install ok installed'; then
    echo "already installed: ${pkg}"
  else
    missing+=("${pkg}")
  fi
done

if ((${#missing[@]} == 0)); then
  echo "packaging tools already present"
else
  echo "installing: ${missing[*]}"
  sudo systemctl stop unattended-upgrades.service apt-daily.service apt-daily-upgrade.timer apt-daily-upgrade.service 2>/dev/null || true
  sudo killall -q unattended-upgrades apt-get apt || true

  echo "waiting for dpkg/apt locks"
  for _ in $(seq 1 30); do
    if ! sudo fuser /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock /var/cache/apt/archives/lock >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done

  apt_opts=(
    -o Acquire::Retries=5
    -o Acquire::http::Timeout=20
    -o Acquire::https::Timeout=20
    -o DPkg::Lock::Timeout=60
    -o Dpkg::Use-Pty=0
  )
  sudo apt-get "${apt_opts[@]}" update
  sudo DEBIAN_FRONTEND=noninteractive apt-get "${apt_opts[@]}" install -y --no-install-recommends "${missing[@]}"
fi

command -v mcopy >/dev/null
command -v xorriso >/dev/null
if ! command -v mkfs.vfat >/dev/null && ! command -v mkfs.fat >/dev/null; then
  echo "mkfs.vfat/mkfs.fat missing after install" >&2
  exit 1
fi
echo "packaging tools ready"
