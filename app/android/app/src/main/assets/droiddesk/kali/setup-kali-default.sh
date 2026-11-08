#!/usr/bin/env bash
set -Eeuo pipefail

export HOME=/root
export USER=root
export LOGNAME=root
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export LANG=C.UTF-8
export TERM=dumb
export DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none
export BASH_ENV=/dev/null

readonly APT_SOURCE_FILE="/etc/apt/sources.list.d/droiddesk-kali.sources"
readonly APT_SOURCE_BACKUP="/root/.droiddesk/apt-sources-original"

# Direct HTTPS endpoints operated by Kali. The mirror redirector is avoided
# because it may select mirrors whose package URLs use HTTP.
readonly KALI_PRIMARY="https://kali.download/kali/"
readonly KALI_FALLBACK="https://archive.kali.org/kali/"

APT_OPTIONS=(
  -o Acquire::ForceIPv4=true
  -o Acquire::Retries=3
  -o Acquire::http::Timeout=20
  -o Acquire::https::Timeout=60
  -o Acquire::https::Verify-Peer=true
  -o Acquire::https::Verify-Host=true
  -o Acquire::AllowDowngradeToInsecureRepositories=false
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

# CI-only validation mode. This does not modify /etc, /var, dpkg, or the network.
if [[ "\${1:-}" == "--self-test" ]]; then
  [[ "$KALI_PRIMARY" == "https://kali.download/kali/" ]]
  [[ "$KALI_FALLBACK" == "https://archive.kali.org/kali/" ]]
  [[ "$KALI_PRIMARY" != "$KALI_FALLBACK" ]]
  [[ " \${APT_OPTIONS[*]} " == *"Acquire::ForceIPv4=true"* ]]
  [[ " \${APT_OPTIONS[*]} " == *"Acquire::https::Verify-Peer=true"* ]]
  [[ " \${APT_OPTIONS[*]} " == *"Acquire::https::Verify-Host=true"* ]]
  printf '%s\n' "[DroidDesk Kali] APT setup configuration checks passed."
  exit 0
fi

prepare_apt_directories() {
  install -d -m 0755 /var/cache/apt/archives
  install -d -m 0700 /var/cache/apt/archives/partial
  install -d -m 0755 /var/lib/apt/lists
  install -d -m 0700 /var/lib/apt/lists/partial
  install -d -m 1777 /tmp
  install -d -m 0755 /var/tmp

  # Keep completed packages for reuse, but remove interrupted partial files.
  find /var/cache/apt/archives/partial -mindepth 1 -maxdepth 1 -type f -delete
  find /var/lib/apt/lists/partial -mindepth 1 -maxdepth 1 -type f -delete
}

clear_stale_apt_indexes() {
  # Remove stale index metadata, but preserve downloaded .deb files and dpkg state.
  find /var/lib/apt/lists -mindepth 1 -maxdepth 1 -type f -delete
  find /var/lib/apt/lists/partial -mindepth 1 -maxdepth 1 -type f -delete
}

configure_official_kali_source() {
  local repository_uri="$1"
  local source_backup_name

  case "$repository_uri" in
    "https://kali.download/kali/"|"https://archive.kali.org/kali/")
      ;;
    *)
      echo "[DroidDesk Kali] Refusing an unapproved or non-HTTPS repository: $repository_uri"
      return 1
      ;;
  esac

  if [[ ! -s /usr/share/keyrings/kali-archive-keyring.gpg ]]; then
    echo "[DroidDesk Kali] Kali archive signing key is missing; refusing an unsigned repository."
    return 1
  fi

  install -d -m 0755 /etc/apt/sources.list.d
  install -d -m 0700 "$APT_SOURCE_BACKUP"

  # Preserve original source files once, then use one controlled source file.
  shopt -s nullglob
  local source_files=(
    /etc/apt/sources.list
    /etc/apt/sources.list.d/*.list
    /etc/apt/sources.list.d/*.sources
  )

  for source_file in "\${source_files[@]}"; do
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

  if ! grep -Eq '^URIs: https://(kali\.download|archive\.kali\.org)/kali/$' "$APT_SOURCE_FILE"; then
    echo "[DroidDesk Kali] The configured source did not pass the HTTPS allow-list check."
    return 1
  fi
}

run_apt_transaction() {
  local repository_uri="$1"

  echo "[DroidDesk Kali] Using official HTTPS repository: $repository_uri"
  if ! configure_official_kali_source "$repository_uri"; then
    echo "[DroidDesk Kali] Could not configure the official repository."
    return 1
  fi

  if ! prepare_apt_directories; then
    echo "[DroidDesk Kali] Could not prepare APT cache directories."
    return 1
  fi

  echo "[DroidDesk Kali] Updating package indexes over HTTPS..."
  if ! apt-get "\${APT_OPTIONS[@]}" update; then
    echo "[DroidDesk Kali] Repository index update failed: $repository_uri"
    return 1
  fi

  # Complete packages unpacked by an earlier interrupted attempt.
  if ! dpkg --configure -a; then
    echo "[DroidDesk Kali] Repairing the interrupted dpkg transaction..."
    if ! apt-get "\${APT_OPTIONS[@]}" --fix-broken install -y; then
      echo "[DroidDesk Kali] The existing dpkg transaction could not be repaired."
      return 1
    fi
  fi

  if ! prepare_apt_directories; then
    echo "[DroidDesk Kali] Could not prepare APT cache directories."
    return 1
  fi

  echo "[DroidDesk Kali] Installing Kali default tools and XFCE..."
  apt-get "\${APT_OPTIONS[@]}" install -y "\${APT_PACKAGES[@]}"
}

echo "[DroidDesk Kali] Preparing APT cache and temporary directories..."
if ! prepare_apt_directories; then
  echo "[DroidDesk Kali] Could not prepare the APT cache."
  exit 1
fi

clear_stale_apt_indexes

INSTALL_SUCCEEDED=0
for repository_uri in "$KALI_PRIMARY" "$KALI_FALLBACK"; do
  if run_apt_transaction "$repository_uri"; then
    INSTALL_SUCCEEDED=1
    break
  fi

  echo "[DroidDesk Kali] Repository attempt failed; preserving completed downloads and repairing dpkg state..."
  dpkg --configure -a || true
  prepare_apt_directories || true
done

if [[ "$INSTALL_SUCCEEDED" -ne 1 ]]; then
  echo "[DroidDesk Kali] Installation failed through both official HTTPS repositories."
  echo "[DroidDesk Kali] Check that the phone can reach HTTPS on port 443, then reopen Install Kali Linux."
  exit 100
fi

echo "[DroidDesk Kali] Verifying the requested package set..."
dpkg-query -W -f='\${Status}' kali-linux-default | grep -qx 'install ok installed'
test -x /usr/bin/startxfce4
test -x /usr/bin/dbus-launch
test -x /usr/bin/xfce4-session

echo "[DroidDesk Kali] Package installation and verification completed."
