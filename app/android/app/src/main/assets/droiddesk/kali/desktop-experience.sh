#!/usr/bin/env bash
set -Eeuo pipefail

export HOME=/root USER=root LOGNAME=root
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export LANG=C.UTF-8 TERM=dumb DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none BASH_ENV=/dev/null

readonly FEATURE_DIR="/root/.droiddesk"
readonly FEATURE_MARKER="$FEATURE_DIR/desktop-experience-v2"
readonly LOG_FILE="$FEATURE_DIR/desktop-experience.log"
readonly WALLPAPER_DIR="/usr/share/xfce4/backdrops/Kali Linux"

REQUIRED_PACKAGES=(
  kali-wallpapers-2026 gvfs gvfs-backends pulseaudio-utils libasound2-plugins
  ffmpeg libavcodec-extra gstreamer1.0-libav
  gdebi zenity desktop-file-utils xdg-utils curl gnupg
)

if [[ "${1:-}" == "--self-test" ]]; then
  [[ "$WALLPAPER_DIR" == "/usr/share/xfce4/backdrops/Kali Linux" ]]
  [[ "$FEATURE_MARKER" == "/root/.droiddesk/desktop-experience-v2" ]]
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
  if ! package_installed "$package"; then missing_packages+=("$package"); fi
done

if (("${#missing_packages[@]}" > 0)); then
  echo "[Kali Linux] Installing browser codecs, wallpapers and package-installer support..."
  apt-get -o Acquire::ForceIPv4=true -o Acquire::Retries=3 -o Acquire::http::Timeout=25 -o Acquire::https::Timeout=45 -o Dpkg::Use-Pty=0 update
  apt-get -o Acquire::Retries=3 -o Dpkg::Use-Pty=0 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold install -y --no-install-recommends "${missing_packages[@]}"
fi

for package in "${REQUIRED_PACKAGES[@]}"; do
  if ! package_installed "$package"; then
    echo "[Kali Linux] Required package did not configure: $package"
    exit 20
  fi
done

# Official Google Chrome ARM64 repository; failure does not block XFCE startup.
# Select Chrome only when its signed ARM64 package really installed; otherwise keep a working Firefox handler.
helpers_file="/home/kali/.config/xfce4/helpers.rc"
install -d -m 0755 "$(dirname "$helpers_file")"
if package_installed google-chrome-stable && [[ -f /usr/share/applications/google-chrome.desktop ]]; then
  printf 'FileManager=Thunar\nWebBrowser=google-chrome.desktop\n' > "$helpers_file"
elif [[ -f /usr/share/applications/firefox-esr.desktop ]]; then
  printf 'FileManager=Thunar\nWebBrowser=firefox-esr.desktop\n' > "$helpers_file"
elif [[ -f /usr/share/applications/firefox.desktop ]]; then
  printf 'FileManager=Thunar\nWebBrowser=firefox.desktop\n' > "$helpers_file"
fi

if ! package_installed google-chrome-stable; then
  key_tmp="$(mktemp)"
  if curl -fsSL --retry 3 --connect-timeout 20 https://dl.google.com/linux/linux_signing_key.pub -o "$key_tmp" &&
     gpg --dearmor --yes -o /usr/share/keyrings/google-chrome.gpg "$key_tmp"; then
    chmod 0644 /usr/share/keyrings/google-chrome.gpg
    printf '%s\n' 'deb [arch=arm64 signed-by=/usr/share/keyrings/google-chrome.gpg] https://dl.google.com/linux/chrome/deb/ stable main' > /etc/apt/sources.list.d/google-chrome.list
    if apt-get -o Acquire::Retries=3 -o Acquire::https::Timeout=45 update &&
       apt-get -o Dpkg::Use-Pty=0 install -y --no-install-recommends google-chrome-stable; then
      echo "[Kali Linux] Official Google Chrome ARM64 package installed."
    else
      echo "[Kali Linux] Chrome repository/install unavailable; continuing with the existing browser."
      rm -f /etc/apt/sources.list.d/google-chrome.list
    fi
  else
    echo "[Kali Linux] Could not verify Google's signing key; Chrome installation skipped."
  fi
  rm -f "$key_tmp"
fi

# Collect Kali wallpapers into one selectable XFCE folder.
install -d -m 0755 "$WALLPAPER_DIR"
while IFS= read -r -d '' image_file; do
  image_name="$(basename "$image_file")"
  ln -sfn "$image_file" "$WALLPAPER_DIR/$image_name"
done < <(
  find /usr/share -type f \
    \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' -o -iname '*.svg' \) \
    \( -ipath '*/backgrounds/*' -o -ipath '*/wallpapers/*' \) -print0
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
  current_wallpaper="$(sed -n 's/.*name="last-image"[^>]*value="\([^"]*\)".*/\1/p' "$desktop_xml" | head -n 1)"
  case "$current_wallpaper" in
    "$WALLPAPER_DIR"/*) [[ -f "$current_wallpaper" ]] || current_wallpaper="" ;;
    *) current_wallpaper="" ;;
  esac
  if [[ -z "$current_wallpaper" ]]; then
    first_wallpaper="$(find "$WALLPAPER_DIR" -maxdepth 1 -type l -print | sort | head -n 1 || true)"
    if [[ -n "$first_wallpaper" ]]; then
      sed -i "0,/name=\"last-image\"/s#value=\"[^\"]*\"#value=\"$first_wallpaper\"#" "$desktop_xml"
    fi
  fi
fi

# Style 0 removes the panel background without depending on a software compositor.
panel_xml="/home/kali/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-panel.xml"
if [[ -f "$panel_xml" ]]; then
  sed -i '/<property name="panel-2" type="empty">/,/<property name="plugin-ids"/ s#<property name="background-style" type="uint" value="[0-9]*"/>#<property name="background-style" type="uint" value="0"/>#' "$panel_xml"
fi

# Keep XFCE software compositing disabled; the Android X11 surface already composites.
xfwm_xml="/home/kali/.config/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml"
if [[ -f "$xfwm_xml" ]]; then
  if grep -q 'name="use_compositing"' "$xfwm_xml"; then
    sed -i -E 's#(<property name="use_compositing" type="bool" value=")true("/>)#\1false\2#' "$xfwm_xml"
  else
    sed -i '/<property name="general" type="empty">/a\            <property name="use_compositing" type="bool" value="false"/>' "$xfwm_xml"
  fi
fi

# A real launcher ensures Trash remains accessible even if xfdesktop/GVFS is late.
install -d -m 0755 /home/kali/Desktop
cat > /home/kali/Desktop/Trash.desktop <<'TRASH'
[Desktop Entry]
Version=1.0
Type=Application
Name=Trash
Comment=Open deleted files
Exec=thunar trash:///
Icon=user-trash
Terminal=false
StartupNotify=true
TRASH
chmod 0755 /home/kali/Desktop/Trash.desktop

# Open downloaded .deb files in the installer; AppImages get menu + desktop launchers.
install -d -m 0755 /home/kali/.local/bin /home/kali/.local/share/applications
cat > /home/kali/.local/bin/droiddesk-install-download <<'INSTALLER'
#!/usr/bin/env bash
set -Eeuo pipefail
export HOME=/home/kali
file="$1"
[[ -f "$file" ]] || exit 1
file="$(readlink -f "$file")"
lower_file="$(printf '%s' "$file" | tr '[:upper:]' '[:lower:]')"
case "$lower_file" in
  *.deb)
    if sudo -n apt-get install -y "$file"; then
      zenity --info --title='Kali Linux' --text='Installed. Find the application in the Applications menu.' 2>/dev/null || true
    else
      zenity --error --title='Installation failed' --text='Could not install this package. Check its architecture and dependencies.' 2>/dev/null || true
      exit 1
    fi
    ;;
  *.appimage)
    install -d "$HOME/Applications" "$HOME/.local/share/applications" "$HOME/Desktop"
    safe_file="$(basename "$file" | tr -cs '[:alnum:]._-' '_')"
    target="$HOME/Applications/$safe_file"
    cp -f "$file" "$target"
    chmod 0755 "$target"
    app_name="${safe_file%.*}"
    desktop="$HOME/.local/share/applications/$app_name.desktop"
    cat > "$desktop" <<ENTRY
[Desktop Entry]
Version=1.0
Type=Application
Name=$app_name
Exec=$target
Icon=application-x-executable
Terminal=false
Categories=Utility;
ENTRY
    cp -f "$desktop" "$HOME/Desktop/$app_name.desktop"
    chmod 0755 "$desktop" "$HOME/Desktop/$app_name.desktop"
    zenity --info --title='Kali Linux' --text="Added $app_name to Applications and Desktop." 2>/dev/null || true
    ;;
  *)
    zenity --error --title='Unsupported file' --text='Choose a .deb or .AppImage file.' 2>/dev/null || true
    exit 2
    ;;
esac
INSTALLER
chmod 0755 /home/kali/.local/bin/droiddesk-install-download

cat > /home/kali/.local/share/applications/droiddesk-install-download.desktop <<'INSTALLER_DESKTOP'
[Desktop Entry]
Version=1.0
Type=Application
Name=Install downloaded Linux app
Comment=Install a Debian package or add an AppImage to Desktop
Exec=/home/kali/.local/bin/droiddesk-install-download %f
Icon=system-software-install
Terminal=false
MimeType=application/vnd.debian.binary-package;application/x-deb;application/x-iso9660-appimage;
INSTALLER_DESKTOP
chmod 0644 /home/kali/.local/share/applications/droiddesk-install-download.desktop

mime_file="/home/kali/.config/mimeapps.list"
install -d -m 0755 /home/kali/.config
touch "$mime_file"
if ! grep -q '^\[Default Applications\]' "$mime_file"; then printf '\n[Default Applications]\n' >> "$mime_file"; fi
for mime in application/vnd.debian.binary-package application/x-deb application/x-iso9660-appimage; do
  if grep -q "^$mime=" "$mime_file"; then
    sed -i "s#^$mime=.*#$mime=droiddesk-install-download.desktop;#" "$mime_file"
  else
    sed -i "/^\[Default Applications\]/a $mime=droiddesk-install-download.desktop;" "$mime_file"
  fi
done

# Prevent expensive thumbnail decoding on the phone.
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

chown -R kali:kali /home/kali/.config /home/kali/.local /home/kali/Desktop /home/kali/Applications 2>/dev/null || true
chown kali:kali /home/kali/.asoundrc 2>/dev/null || true
touch "$FEATURE_MARKER"
chmod 0600 "$FEATURE_MARKER"
echo "[Kali Linux] Desktop experience migration completed."
