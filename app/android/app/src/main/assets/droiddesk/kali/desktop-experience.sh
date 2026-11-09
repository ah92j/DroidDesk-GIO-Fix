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

readonly FEATURE_DIR="/root/.droiddesk"
readonly FEATURE_MARKER="$FEATURE_DIR/desktop-experience-v1"
readonly LOG_FILE="$FEATURE_DIR/desktop-experience.log"
readonly WALLPAPER_DIR="/usr/share/xfce4/backdrops/Kali Linux"

REQUIRED_PACKAGES=(
  kali-wallpapers-2026
  gvfs
  gvfs-backends
  pulseaudio-utils
  libasound2-plugins
)

if [[ "${1:-}" == "--self-test" ]]; then
  for package in "${REQUIRED_PACKAGES[@]}"; do
    [[ -n "$package" ]]
  done
  [[ "$WALLPAPER_DIR" == "/usr/share/xfce4/backdrops/Kali Linux" ]]
  [[ "$FEATURE_MARKER" == "/root/.droiddesk/desktop-experience-v1" ]]
  printf '%s\n' "[Kali Linux] Desktop-experience checks passed."
  exit 0
fi

install -d -m 0700 "$FEATURE_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

package_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -qx 'install ok installed'
}

missing_packages=()
for package in "${REQUIRED_PACKAGES[@]}"; do
  if ! package_installed "$package"; then
    missing_packages+=("$package")
  fi
done

if (("${#missing_packages[@]}" > 0)); then
  echo "[Kali Linux] Installing desktop support packages: ${missing_packages[*]}"
  apt-get \
    -o Acquire::ForceIPv4=true \
    -o Acquire::Retries=3 \
    -o Acquire::http::Timeout=25 \
    -o Acquire::https::Timeout=45 \
    -o APT::Keep-Downloaded-Packages=true \
    -o Dpkg::Use-Pty=0 \
    -o Dpkg::Options::=--force-confdef \
    -o Dpkg::Options::=--force-confold \
    update
  apt-get \
    -o Acquire::Retries=3 \
    -o Dpkg::Use-Pty=0 \
    -o Dpkg::Options::=--force-confdef \
    -o Dpkg::Options::=--force-confold \
    install -y --no-install-recommends "${missing_packages[@]}"
fi

for package in "${REQUIRED_PACKAGES[@]}"; do
  if ! package_installed "$package"; then
    echo "[Kali Linux] Required desktop package did not configure: $package"
    exit 20
  fi
done

# Make official Kali wallpapers visible in XFCE's normal Desktop Settings folder list.
install -d -m 0755 "$WALLPAPER_DIR"
while IFS= read -r -d '' image_file; do
  image_name="${image_file##*/}"
  ln -sfn "$image_file" "$WALLPAPER_DIR/$image_name"
done < <(
  find /usr/share -type f \
    \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' -o -iname '*.svg' \) \
    \( -ipath '*/backgrounds/*' -o -ipath '*/wallpapers/*' \) \
    -print0
)

wallpaper_count="$(find "$WALLPAPER_DIR" -maxdepth 1 -type l | wc -l)"
echo "[Kali Linux] Official wallpaper choices exposed to XFCE: $wallpaper_count"

desktop_xml="/home/kali/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml"
if [[ -f "$desktop_xml" ]]; then
  if ! grep -q 'name="image-path"' "$desktop_xml"; then
    sed -i '\#<property name="monitorbuiltin" type="empty">#a\                <property name="image-path" type="string" value="/usr/share/xfce4/backdrops/Kali Linux"/>' "$desktop_xml"
  fi
  if grep -q 'name="show-trash"' "$desktop_xml"; then
    sed -i -E 's#(<property name="show-trash" type="bool" value=")false("/>)#\1true\2#' "$desktop_xml"
  else
    sed -i '/<property name="show-filesystem"/a\              <property name="show-trash" type="bool" value="true"/>' "$desktop_xml"
  fi
fi

# Turn off XFCE's compositor: Lorie's Android X11 renderer already composites
# the surface, and a second software compositor adds avoidable frame latency.
xfwm_xml="/home/kali/.config/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml"
if [[ -f "$xfwm_xml" ]]; then
  if grep -q 'name="use_compositing"' "$xfwm_xml"; then
    sed -i -E 's#(<property name="use_compositing" type="bool" value=")true("/>)#\1false\2#' "$xfwm_xml"
  else
    sed -i '/<property name="general" type="empty">/a\            <property name="use_compositing" type="bool" value="false"/>' "$xfwm_xml"
  fi
fi

# Avoid expensive thumbnail decoding while browsing the rootfs on a mobile device.
thunar_config="/home/kali/.config/Thunar/thunarrc"
install -d -m 0755 "$(dirname "$thunar_config")"
if [[ ! -f "$thunar_config" ]]; then
  printf '[Configuration]\nMiscShowThumbnails=NEVER\n' > "$thunar_config"
elif grep -q '^MiscShowThumbnails=' "$thunar_config"; then
  sed -i 's/^MiscShowThumbnails=.*/MiscShowThumbnails=NEVER/' "$thunar_config"
elif grep -q '^\[Configuration\]' "$thunar_config"; then
  sed -i '/^\[Configuration\]/a MiscShowThumbnails=NEVER' "$thunar_config"
else
  printf '\n[Configuration]\nMiscShowThumbnails=NEVER\n' >> "$thunar_config"
fi

# Let ALSA applications share the same Android-backed PulseAudio output.
if [[ ! -e /home/kali/.asoundrc ]]; then
  cat > /home/kali/.asoundrc <<'ALSA'
pcm.!default {
  type pulse
}
ctl.!default {
  type pulse
}
ALSA
fi

chown -R kali:kali /home/kali/.config /home/kali/.local 2>/dev/null || true
chown kali:kali /home/kali/.asoundrc 2>/dev/null || true
touch "$FEATURE_MARKER"
chmod 0600 "$FEATURE_MARKER"
echo "[Kali Linux] Desktop experience migration completed."
