#!/usr/bin/env bash
set -Eeuo pipefail

export HOME=/root
export USER=root
export LOGNAME=root
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export LANG=C.UTF-8
export TERM=xterm-256color
export DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none

readonly APT_SOURCE_FILE="/etc/apt/sources.list.d/droiddesk-kali.sources"
readonly APT_SOURCE_BACKUP="/root/.droiddesk/apt-sources-original"
# Use Kali's HTTPS mirror redirector first. It selects a mirror with
# HTTPS enabled, avoiding the HTTP port 80 that was unreachable on the phone.
# The fallback is a Kali-operated HTTPS mirror (not a community HTTP mirror).
readonly KALI_PRIMARY="https://http.kali.org/kali/"
readonly KALI_FALLBACK="https://archive-3.kali.org/kali/"

APT_OPTIONS=(
  -o Acquire::ForceIPv4=true
  -o Acquire::Retries=5
  -o Acquire::http::Timeout=30
  -o Acquire::https::Timeout=90
  -o Acquire::https::Verify-Peer=true
  -o Acquire::https::Verify-Host=true
  -o Acquire::Queue-Mode=access
  -o Dpkg::Use-Pty=0
  -o Dpkg::Options::=--force-confdef
  -o Dpkg::Options::=--force-confold
)

APT_PACKAGES=(
  kali-linux-default
  xfce4
  xfce4-terminal
  dbus-x11
  xclip
  x11-utils
  papirus-icon-theme
  fonts-noto-core
)

prepare_apt_directories() {
  # APT's downloader writes to these partial directories before renaming a
  # completed .deb into archives/. If they are missing, a successful transfer
  # can still fail with "rename failed: No such file or directory".
  install -d -m 0755 /var/cache/apt/archives
  install -d -m 0700 /var/cache/apt/archives/partial
  install -d -m 0755 /var/lib/apt/lists
  install -d -m 0700 /var/lib/apt/lists/partial
  install -d -m 1777 /tmp
  install -d -m 0755 /var/tmp

  # Discard only incomplete downloads; keep completed .deb files so retries
  # can reuse them and dpkg can continue configuring already unpacked packages.
  find /var/cache/apt/archives/partial -mindepth 1 -maxdepth 1 -type f -delete
  find /var/lib/apt/lists/partial -mindepth 1 -maxdepth 1 -type f -delete
}

clear_stale_apt_indexes() {
  # Indexes from a previous failed HTTP mirror attempt can retain mirror paths.
  # Remove index files once before the first update; package .deb cache is kept.
  find /var/lib/apt/lists -mindepth 1 -maxdepth 1 -type f -delete
}

configure_official_kali_source() {
  local repository_uri="$1"
  local source_backup_name

  install -d -m 0755 /etc/apt/sources.list.d
  install -d -m 0700 "$APT_SOURCE_BACKUP"

  # Preserve the rootfs defaults, then disable duplicate Kali entries. A
  # single official source prevents APT from spreading package requests over
  # several mirrors that may not be reachable from the phone's network.
  shopt -s nullglob
  local source_files=(
    /etc/apt/sources.list
    /etc/apt/sources.list.d/*.list
    /etc/apt/sources.list.d/*.sources
  )

  for source_file in "${source_files[@]}"; do
    [[ -f "$source_file" ]] || continue
    [[ "$source_file" == "$APT_SOURCE_FILE" ]] && continue

    source_backup_name="$(basename "$source_file").original"
    if [[ ! -e "$APT_SOURCE_BACKUP/$source_backup_name" ]]; then
      cp -p "$source_file" "$APT_SOURCE_BACKUP/$source_backup_name"
    fi

    if [[ "$source_file" == "/etc/apt/sources.list" ]]; then
      : > "$source_file"
    else
      rm -f "$source_file"
    fi
  done

  cat > "$APT_SOURCE_FILE" <<EOF
Types: deb
URIs: $repository_uri
Suites: kali-rolling
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/kali-archive-keyring.gpg
EOF

  if ! grep -Eq '^URIs: https://[^[:space:]]+/?

run_apt_transaction() {
  local repository_uri="$1"

  echo "[DroidDesk Kali] Using official repository: $repository_uri"
  if ! configure_official_kali_source "$repository_uri"; then
    echo "[DroidDesk Kali] Could not configure the official repository: $repository_uri"
    return 1
  fi
  if ! prepare_apt_directories; then
    echo "[DroidDesk Kali] Could not prepare APT cache directories."
    return 1
  fi

  echo "[DroidDesk Kali] Updating package indexes (automatic retries enabled)..."
  if ! apt-get "${APT_OPTIONS[@]}" update; then
    echo "[DroidDesk Kali] Repository index update failed: $repository_uri"
    return 1
  fi

  # Recover packages already unpacked by an earlier interrupted attempt.
  if ! dpkg --configure -a; then
    echo "[DroidDesk Kali] Completing any interrupted package configuration..."
    apt-get "${APT_OPTIONS[@]}" --fix-broken install -y || true
  fi

  prepare_apt_directories
  echo "[DroidDesk Kali] Installing Kali default tools and XFCE..."
  apt-get "${APT_OPTIONS[@]}" install -y "${APT_PACKAGES[@]}"
}

echo "[DroidDesk Kali] Preparing APT cache and temporary directories..."
prepare_apt_directories

# Remove stale index metadata from earlier HTTP attempts while preserving
# completed package downloads and dpkg state.
clear_stale_apt_indexes

# Both endpoints use HTTPS. The first is Kali's official mirror redirector,
# which selects an SSL-enabled mirror; the fallback is operated by Kali.
INSTALL_SUCCEEDED=0
for repository_uri in "$KALI_PRIMARY" "$KALI_FALLBACK"; do
  if run_apt_transaction "$repository_uri"; then
    INSTALL_SUCCEEDED=1
    break
  fi

  echo "[DroidDesk Kali] APT attempt failed; preserving completed downloads and repairing dpkg state..."
  dpkg --configure -a || true
  apt-get "${APT_OPTIONS[@]}" --fix-broken install -y || true
  prepare_apt_directories
done

if [[ "$INSTALL_SUCCEEDED" -ne 1 ]]; then
  echo "[DroidDesk Kali] Installation could not complete from either official Kali repository."
  echo "[DroidDesk Kali] Check that the phone can reach HTTPS on port 443, then reopen Install Kali Linux."
  exit 100
fi

echo "[DroidDesk Kali] Verifying the requested package set..."
dpkg-query -W -f='${Status}' kali-linux-default | grep -qx 'install ok installed'
test -x /usr/bin/startxfce4
test -x /usr/bin/dbus-launch
test -x /usr/bin/xfce4-session

echo "[DroidDesk Kali] Package installation and verification completed."
 "$APT_SOURCE_FILE"; then
    echo "[DroidDesk Kali] Refusing a non-HTTPS Kali repository."
    return 1
  fi

  if [[ ! -s /usr/share/keyrings/kali-archive-keyring.gpg ]]; then
    echo "[DroidDesk Kali] Kali archive signing key is missing; refusing an unsigned repository."
    return 1
  fi
}

run_apt_transaction() {
  local repository_uri="$1"

  echo "[DroidDesk Kali] Using official repository: $repository_uri"
  if ! configure_official_kali_source "$repository_uri"; then
    echo "[DroidDesk Kali] Could not configure the official repository: $repository_uri"
    return 1
  fi
  if ! prepare_apt_directories; then
    echo "[DroidDesk Kali] Could not prepare APT cache directories."
    return 1
  fi

  echo "[DroidDesk Kali] Updating package indexes (automatic retries enabled)..."
  if ! apt-get "${APT_OPTIONS[@]}" update; then
    echo "[DroidDesk Kali] Repository index update failed: $repository_uri"
    return 1
  fi

  # Recover packages already unpacked by an earlier interrupted attempt.
  if ! dpkg --configure -a; then
    echo "[DroidDesk Kali] Completing any interrupted package configuration..."
    apt-get "${APT_OPTIONS[@]}" --fix-broken install -y || true
  fi

  prepare_apt_directories
  echo "[DroidDesk Kali] Installing Kali default tools and XFCE..."
  apt-get "${APT_OPTIONS[@]}" install -y "${APT_PACKAGES[@]}"
}

echo "[DroidDesk Kali] Preparing APT cache and temporary directories..."
prepare_apt_directories

# First use Kali's official Cloudflare CDN, which avoids the geographically
# selected community mirror that was unreachable on the previous attempt.
# If the CDN is unavailable on the current network, retry through Kali's
# official mirror redirector as a fallback.
INSTALL_SUCCEEDED=0
for repository_uri in "$KALI_CDN" "$KALI_REDIRECTOR"; do
  if run_apt_transaction "$repository_uri"; then
    INSTALL_SUCCEEDED=1
    break
  fi

  echo "[DroidDesk Kali] APT attempt failed; preserving completed downloads and repairing dpkg state..."
  dpkg --configure -a || true
  apt-get "${APT_OPTIONS[@]}" --fix-broken install -y || true
  prepare_apt_directories
done

if [[ "$INSTALL_SUCCEEDED" -ne 1 ]]; then
  echo "[DroidDesk Kali] Installation could not complete from either official Kali repository."
  echo "[DroidDesk Kali] Check that the phone can reach kali.download or http.kali.org, then reopen Install Kali Linux."
  exit 100
fi

echo "[DroidDesk Kali] Verifying the requested package set..."
dpkg-query -W -f='${Status}' kali-linux-default | grep -qx 'install ok installed'
test -x /usr/bin/startxfce4
test -x /usr/bin/dbus-launch
test -x /usr/bin/xfce4-session

echo "[DroidDesk Kali] Package installation and verification completed."
