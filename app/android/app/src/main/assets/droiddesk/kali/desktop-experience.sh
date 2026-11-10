#!/usr/bin/env bash
set -Eeuo pipefail

export HOME=/root USER=root LOGNAME=root
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export LANG=C.UTF-8 TERM=dumb DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none BASH_ENV=/dev/null

readonly FEATURE_DIR="/root/.droiddesk"
readonly FEATURE_MARKER="$FEATURE_DIR/desktop-experience-v11"
readonly LOG_FILE="$FEATURE_DIR/desktop-experience.log"
readonly WALLPAPER_DIR="/usr/share/xfce4/backdrops/Kali Linux"

REQUIRED_PACKAGES=(
  kali-wallpapers-2026 firefox-esr libpulse0 gvfs gvfs-daemons gvfs-backends pulseaudio-utils libasound2-plugins
  ffmpeg gstreamer1.0-libav gstreamer1.0-plugins-good
  gdebi zenity desktop-file-utils xdg-utils curl gnupg file tar
)

if [[ "${1:-}" == "--self-test" ]]; then
  [[ "$WALLPAPER_DIR" == "/usr/share/xfce4/backdrops/Kali Linux" ]]
  grep -q 'gvfs-daemons' "$0"
  grep -q 'kali-cubes2-16x9.jpg' "$0"
  grep -q 'kali-wallpapers-2026' "$0"
  [[ "$FEATURE_MARKER" == "/root/.droiddesk/desktop-experience-v11" ]]
  grep -q 'apt-cache depends firefox-esr' "$0"
  grep -q 'libavcodec-extra' "$0"
  grep -q "media.rdd-ffmpeg.enabled" "$0"
  grep -q 'user_pref("media.rdd-process.enabled", true);' "$0"
  grep -q 'user_pref("media.rdd-ffmpeg.enabled", true);' "$0"
  grep -q "MOZ_DISABLE_RDD_SANDBOX" "$0"
  grep -q "Preserve existing XFCE preferences" "$0"
  grep -q "policy-rc.d" "$0"
  grep -q "Still working:" "$0"
  grep -q "pulse_ready=0" "$0"
  grep -q "export LIBGL_ALWAYS_SOFTWARE=1" "$0"
  grep -q 'gfx.webrender.software' "$0"
  grep -q 'layers.acceleration.disabled' "$0"
  grep -q "launch-time diagnostics" "$0"
  grep -q "kali-wallpapers-2026" "$0"
  ! grep -Eq '(^|[[:space:]])--install-recommends([[:space:]]|$)' "$0"
  printf '%s\n' "[Kali Linux] Desktop-experience checks passed."
  exit 0
fi

install -d -m 0700 "$FEATURE_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

package_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -qx 'install ok installed'
}

configure_proot_service_policy() {
  install -d -m 0755 /usr/sbin
  if [[ ! -e /usr/sbin/policy-rc.d ]]; then
    cat > /usr/sbin/policy-rc.d <<'POLICY'
#!/bin/sh
exit 101
POLICY
    chmod 0755 /usr/sbin/policy-rc.d
  fi
}

run_with_package_heartbeat() {
  local label="$1"
  shift
  "$@" &
  local command_pid=$!
  (
    while kill -0 "$command_pid" 2>/dev/null; do
      sleep 15
      if kill -0 "$command_pid" 2>/dev/null; then
        latest_event="$(tail -n 1 /var/log/dpkg.log 2>/dev/null || true)"
        echo "[Kali Linux] Still working: $label. Last dpkg activity: ${latest_event:-No dpkg event recorded yet}"
      fi
    done
  ) &
  local heartbeat_pid=$!
  local command_status=0
  if wait "$command_pid"; then command_status=0; else command_status=$?; fi
  kill "$heartbeat_pid" 2>/dev/null || true
  wait "$heartbeat_pid" 2>/dev/null || true
  return "$command_status"
}

configure_proot_service_policy
APT_OPTIONS=(
  -o Acquire::ForceIPv4=true
  -o Acquire::Retries=3
  -o Acquire::http::Timeout=25
  -o Acquire::https::Timeout=45
  -o Acquire::https::Verify-Peer=true
  -o Acquire::https::Verify-Host=true
  -o APT::Keep-Downloaded-Packages=true
  -o Dpkg::Use-Pty=0
  -o Dpkg::Options::=--force-confdef
  -o Dpkg::Options::=--force-confold
)

run_with_package_heartbeat "refreshing Kali ARM64 package indexes" apt-get "${APT_OPTIONS[@]}" update
if ! run_with_package_heartbeat "finishing interrupted package configuration" dpkg --configure -a; then
  run_with_package_heartbeat "repairing interrupted package dependencies" env DEBIAN_FRONTEND=noninteractive apt-get "${APT_OPTIONS[@]}" --fix-broken install -y --no-install-recommends
  run_with_package_heartbeat "completing repaired package configuration" dpkg --configure -a
fi
if dpkg --audit | grep -q .; then
  run_with_package_heartbeat "repairing incomplete package database" env DEBIAN_FRONTEND=noninteractive apt-get "${APT_OPTIONS[@]}" --fix-broken install -y --no-install-recommends
  run_with_package_heartbeat "finishing package database repair" dpkg --configure -a
fi
if dpkg --audit | grep -q .; then
  echo "[Kali Linux] dpkg still reports incomplete packages; migration stopped safely."
  exit 23
fi

missing_packages=()
for package in "${REQUIRED_PACKAGES[@]}"; do
  if ! package_installed "$package"; then missing_packages+=("$package"); fi
done

if (("${#missing_packages[@]}" > 0)); then
  echo "[Kali Linux] Installing only required ARM64 desktop, codecs and installer support (without optional recommendations)..."
  run_with_package_heartbeat "installing required desktop packages" env DEBIAN_FRONTEND=noninteractive apt-get "${APT_OPTIONS[@]}" --no-install-recommends install -y "${missing_packages[@]}"
fi

for package in "${REQUIRED_PACKAGES[@]}"; do
  if ! package_installed "$package"; then
    echo "[Kali Linux] Required package did not configure: $package"
    exit 20
  fi
done

# Preserve custom wallpaper, panel/dock settings and desktop icon positions on upgrade.
PRESERVE_DIR="$(mktemp -d /tmp/droiddesk-xfce-preserve.XXXXXX)"
PRESERVE_ARCHIVE="$PRESERVE_DIR/user-xfce-settings.tar"
PRESERVE_TEMP="$PRESERVE_DIR/user-xfce-settings.tmp"
PRESERVE_READY=0
PRESERVE_ITEMS=()
for item in \
  .config/xfce4/xfconf/xfce-perchannel-xml \
  .config/xfce4/desktop \
  .config/xfce4/panel; do
  if [[ -e "/home/kali/$item" ]]; then
    PRESERVE_ITEMS+=("$item")
  fi
done
restore_user_xfce_preferences() {
  if ((PRESERVE_READY == 1)) && [[ -s "$PRESERVE_ARCHIVE" ]]; then
    if tar -xf "$PRESERVE_ARCHIVE" -C /home/kali; then
      chown -R kali:kali /home/kali/.config/xfce4 2>/dev/null || true
      echo "[Kali Linux] Restored the user's wallpaper, dock and desktop icon layout."
    else
      echo "[Kali Linux] WARNING: saved XFCE preferences could not be restored."
    fi
  fi
  rm -rf "$PRESERVE_DIR"
}
trap restore_user_xfce_preferences EXIT
if ((${#PRESERVE_ITEMS[@]} > 0)); then
  if tar -cf "$PRESERVE_TEMP" -C /home/kali "${PRESERVE_ITEMS[@]}"; then
    mv "$PRESERVE_TEMP" "$PRESERVE_ARCHIVE"
    PRESERVE_READY=1
    echo "[Kali Linux] Saved existing wallpaper, panel settings and desktop icon positions."
  else
    echo "[Kali Linux] WARNING: could not snapshot XFCE settings; migration will not replace existing files."
  fi
fi

# Ensure Firefox exists without forcing a reinstall or pulling optional recommendations.
echo "[Kali Linux] Ensuring Firefox ESR is configured for ARM64..."
run_with_package_heartbeat "installing or verifying Firefox ESR" env DEBIAN_FRONTEND=noninteractive apt-get "${APT_OPTIONS[@]}" --no-install-recommends install -y firefox-esr
if ! package_installed firefox-esr; then
  echo "[Kali Linux] Firefox ESR is not configured after package recovery."
  exit 22
fi

# Prefer the FFmpeg package recommended by the installed Firefox ESR build.
# Fall back to the ABI exposed by the system FFmpeg libraries when recommendations are absent.
codec_candidate="$(apt-cache depends firefox-esr 2>/dev/null |
  sed -nE 's/.*(libavcodec(-extra)?[0-9]+).*/\1/p' | head -n1)"
codec_abi="$(ldconfig -p 2>/dev/null |
  sed -n 's/^[[:space:]]*libavcodec\.so\.\([0-9][0-9]*\) .*/\1/p' |
  sort -rn | head -n1)"
if [[ -z "$codec_candidate" && "$codec_abi" =~ ^[0-9]+$ ]]; then
  codec_candidate="libavcodec-extra$codec_abi"
fi
if [[ -n "$codec_candidate" ]] && apt-cache show "$codec_candidate" 2>/dev/null |
   awk -v wanted="arm64" '/^Architecture:/ { if ($2 == wanted || $2 == "all") found=1 } END { exit !found }'; then
  echo "[Kali Linux] Installing Firefox ESR codec package: $codec_candidate"
  apt-get -o Acquire::Retries=3 -o Dpkg::Use-Pty=0 \
    -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
    install -y --no-install-recommends "$codec_candidate"
  ldconfig 2>/dev/null || true
elif [[ "$codec_abi" =~ ^[0-9]+$ ]] && apt-cache show "libavcodec$codec_abi" 2>/dev/null |
     awk -v wanted="arm64" '/^Architecture:/ { if ($2 == wanted || $2 == "all") found=1 } END { exit !found }'; then
  codec_candidate="libavcodec$codec_abi"
  echo "[Kali Linux] Installing Firefox-compatible ARM64 codec package: $codec_candidate"
  apt-get -o Acquire::Retries=3 -o Dpkg::Use-Pty=0 \
    -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
    install -y --no-install-recommends "$codec_candidate"
  ldconfig 2>/dev/null || true
else
  echo "[Kali Linux] No ARM64 FFmpeg codec package was found in Firefox ESR recommendations or ABI fallback."
  echo "[Kali Linux] Firefox VP9/Opus software decoding remains enabled; H.264/AAC may be unavailable without the matching codec package."
fi

# Install Google Chrome ARM64 from Google's signed repository first.
if ! package_installed google-chrome-stable; then
  key_tmp="$(mktemp)"
  if curl -fsSL --retry 3 --connect-timeout 20 https://dl.google.com/linux/linux_signing_key.pub -o "$key_tmp" &&
     gpg --dearmor --yes -o /usr/share/keyrings/google-chrome.gpg "$key_tmp"; then
    chmod 0644 /usr/share/keyrings/google-chrome.gpg
    printf '%s\n' 'deb [arch=arm64 signed-by=/usr/share/keyrings/google-chrome.gpg] https://dl.google.com/linux/chrome/deb/ stable main' > /etc/apt/sources.list.d/google-chrome.list
    if apt-get -o Acquire::ForceIPv4=true -o Acquire::Retries=3 -o Acquire::https::Timeout=45 update &&
       apt-get -o Dpkg::Use-Pty=0 install -y --no-install-recommends google-chrome-stable; then
      echo "[Kali Linux] Google Chrome ARM64 installed from Google's signed repository."
    else
      rm -f /etc/apt/sources.list.d/google-chrome.list
    fi
  fi
  rm -f "$key_tmp"
fi
# If the repo install did not work, use Google's official ARM64 .deb and validate architecture.
if ! package_installed google-chrome-stable; then
  chrome_deb="$(mktemp --suffix=.deb)"
  if curl -fL --retry 3 --connect-timeout 20 https://dl.google.com/linux/direct/google-chrome-stable_current_arm64.deb -o "$chrome_deb" &&
     [[ "$(dpkg-deb -f "$chrome_deb" Architecture 2>/dev/null || true)" == "arm64" ]] &&
     apt-get -o Dpkg::Use-Pty=0 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold install -y --no-install-recommends "$chrome_deb"; then
    echo "[Kali Linux] Google Chrome ARM64 installed from official ARM64 .deb."
  else
    echo "[Kali Linux] Chrome ARM64 package unavailable; Firefox remains the fallback."
  fi
  rm -f "$chrome_deb"
fi

# One proper browser helper serves both the bottom dock and XFCE browser menu.
install -d -m 0755 /home/kali/.config/xfce4 /home/kali/.local/bin /home/kali/.local/share/applications /home/kali/Desktop
cat > /home/kali/.local/bin/droiddesk-browser <<'BROWSER'
#!/usr/bin/env bash
set -euo pipefail
if [[ -x /usr/bin/google-chrome-stable ]]; then
  exec /usr/bin/google-chrome-stable --no-sandbox --disable-dev-shm-usage --ozone-platform=x11 "$@"
fi
if [[ -x /home/kali/.local/bin/droiddesk-firefox ]]; then
  exec /home/kali/.local/bin/droiddesk-firefox "$@"
fi
if [[ -x /usr/bin/chromium ]]; then
  exec /usr/bin/chromium "$@"
fi
zenity --error --title='Kali Linux' --text='No supported browser is installed.' 2>/dev/null || true
exit 127
BROWSER
chmod 0755 /home/kali/.local/bin/droiddesk-browser
cat > /home/kali/.local/share/applications/droiddesk-browser.desktop <<'BROWSER_DESKTOP'
[Desktop Entry]
Version=1.0
Type=Application
Name=Web Browser
Comment=Open the installed Kali browser
Exec=/home/kali/.local/bin/droiddesk-browser %U
Icon=web-browser
Terminal=false
StartupNotify=true
Categories=Network;WebBrowser;
BROWSER_DESKTOP
chmod 0644 /home/kali/.local/share/applications/droiddesk-browser.desktop
printf '%s\n' 'FileManager=Thunar' 'WebBrowser=droiddesk-browser.desktop' > /home/kali/.config/xfce4/helpers.rc

# Replace the saved browser launcher used by the existing bottom dock.
install -d -m 0755 /home/kali/.config/xfce4/panel/launcher-23
cat > /home/kali/.config/xfce4/panel/launcher-23/droiddesk-browser.desktop <<'DOCK_BROWSER'
[Desktop Entry]
Version=1.0
Type=Application
Name=Web Browser
Comment=Open the installed Kali browser
Exec=/home/kali/.local/bin/droiddesk-browser %U
Icon=web-browser
Terminal=false
StartupNotify=true
DOCK_BROWSER
chmod 0755 /home/kali/.config/xfce4/panel/launcher-23/droiddesk-browser.desktop

# Create an obvious Chrome icon only after the ARM64 binary is present.
if package_installed google-chrome-stable && [[ -x /usr/bin/google-chrome-stable ]]; then
  cat > "/home/kali/Desktop/Google Chrome.desktop" <<'CHROME_DESKTOP'
[Desktop Entry]
Version=1.0
Type=Application
Name=Google Chrome
Comment=Browse with Google Chrome
Exec=/usr/bin/google-chrome-stable --no-sandbox --disable-dev-shm-usage --ozone-platform=x11 %U
Icon=google-chrome
Terminal=false
StartupNotify=true
Categories=Network;WebBrowser;
CHROME_DESKTOP
  chmod 0755 "/home/kali/Desktop/Google Chrome.desktop"
fi

# Firefox ESR wrapper, desktop shortcut and PRoot-friendly media preferences.
cat > /home/kali/.local/bin/droiddesk-firefox <<'FIREFOX'
#!/usr/bin/env bash
set -euo pipefail
export PULSE_SERVER=tcp:127.0.0.1:4713
export PULSE_SINK=droiddesk_android
export PULSE_LATENCY_MSEC=80
# PRoot's X11/GL stack cannot supply the DRI3 shader features Firefox probes.
# Force stable Mesa software rendering and the software WebRender backend.
export LIBGL_ALWAYS_SOFTWARE=1
export MOZ_DISABLE_CONTENT_SANDBOX=1
export MOZ_DISABLE_RDD_SANDBOX=1
export MOZ_DISABLE_GMP_SANDBOX=1
export MOZ_ENABLE_WAYLAND=0
export GDK_BACKEND=x11
pulse_ready=0
if command -v pactl >/dev/null 2>&1; then
  for attempt in $(seq 1 15); do
    if pactl -s "$PULSE_SERVER" list short sinks 2>/dev/null |
       awk '$2 == "droiddesk_android" { found=1 } END { exit !found }'; then
      pulse_ready=1
      break
    fi
    sleep 1
  done
fi
if [[ "$pulse_ready" -eq 1 ]]; then
  pactl -s "$PULSE_SERVER" set-default-sink droiddesk_android >/dev/null 2>&1 || true
  pactl -s "$PULSE_SERVER" set-sink-mute droiddesk_android 0 >/dev/null 2>&1 || true
  echo "[DroidDesk Audio] Firefox connected to the Android AudioTrack sink."
else
  echo "[DroidDesk Audio] ERROR: droiddesk_android PulseAudio sink is unavailable; inspect /tmp/pulse/pulseaudio.log and DroidDesk runtime logs."
fi
firefox_bin="$(command -v firefox-esr || command -v firefox || true)"
if [[ -z "$firefox_bin" ]]; then
  zenity --error --title='Kali Linux' --text='Firefox ESR is not installed.' 2>/dev/null || true
  exit 127
fi
firefox_log="/home/kali/.local/share/droiddesk/firefox-launch.log"
install -d -m 0755 "$(dirname "$firefox_log")"
{
  printf '%s\n' "=== Firefox launch $(date -Is) ==="
  printf '%s\n' "PULSE_SERVER=$PULSE_SERVER"
  printf '%s\n' "LIBGL_ALWAYS_SOFTWARE=$LIBGL_ALWAYS_SOFTWARE"
  pactl -s "$PULSE_SERVER" info 2>&1 || true
  pactl -s "$PULSE_SERVER" list short sinks 2>&1 || true
  ldconfig -p 2>/dev/null | grep -E "libavcodec|libavutil" || true
} >> "$firefox_log" 2>&1
# Regenerate media diagnostics at launch time, after DroidDesk has started PulseAudio.
diagnostic_file="/home/kali/.local/share/droiddesk/firefox-media-diagnostic.txt"
{
  echo "=== Firefox launch-time diagnostics $(date -Is) ==="
  echo "Firefox binary: $firefox_bin"
  firefox-esr --version 2>&1 || firefox --version 2>&1 || true
  dpkg-query -W firefox-esr ffmpeg libavcodec63 2>&1 || true
  echo "=== active graphics environment ==="
  printf 'LIBGL_ALWAYS_SOFTWARE=%s\n' "$LIBGL_ALWAYS_SOFTWARE"
  echo "=== PulseAudio connection and Android sink ==="
  pactl -s "$PULSE_SERVER" info 2>&1 || true
  pactl -s "$PULSE_SERVER" list short sinks 2>&1 || true
  echo "=== software codec support ==="
  ffmpeg -hide_banner -decoders 2>&1 | grep -E ' (aac|h264|vp8|vp9|opus) ' || true
  echo "=== Firefox shared codec backend ==="
  find /usr/lib/firefox-esr /usr/lib/firefox -maxdepth 2 -name 'libmozavcodec.so' -type f -print 2>/dev/null || true
  echo "=== active DroidDesk Firefox preferences ==="
  grep -hE 'layers\.acceleration|gfx\.webrender|gfx\.canvas|gfx\.x11-egl|media\.(rdd-process|rdd-ffmpeg|ffvpx|ffmpeg|mediasource|webm)' \
    /usr/lib/firefox-esr/defaults/pref/droiddesk-media.js \
    /home/kali/.mozilla/firefox/*/user.js 2>/dev/null || true
} > "$diagnostic_file" 2>&1
chmod 0644 "$diagnostic_file" 2>/dev/null || true

echo "[DroidDesk Audio] Firefox launch diagnostics: $firefox_log"
echo "[DroidDesk Media] Fresh media diagnostics: $diagnostic_file"
exec "$firefox_bin" "$@" >> "$firefox_log" 2>&1
FIREFOX
chmod 0755 /home/kali/.local/bin/droiddesk-firefox

if [[ -x /usr/bin/firefox-esr || -x /usr/bin/firefox ]]; then
  cat > /home/kali/.local/share/applications/droiddesk-firefox.desktop <<'FIREFOX_DESKTOP'
[Desktop Entry]
Version=1.0
Type=Application
Name=Firefox
Comment=Browse the web with Firefox
Exec=/home/kali/.local/bin/droiddesk-firefox %U
TryExec=/home/kali/.local/bin/droiddesk-firefox
Icon=firefox-esr
Terminal=false
StartupNotify=true
Categories=Network;WebBrowser;
FIREFOX_DESKTOP
  cp -f /home/kali/.local/share/applications/droiddesk-firefox.desktop /home/kali/Desktop/Firefox.desktop
  chmod 0755 /home/kali/.local/share/applications/droiddesk-firefox.desktop /home/kali/Desktop/Firefox.desktop
fi

# Keep Firefox's isolated RDD media process enabled. Disabling RDD can remove the normal
# external decoder path for H.264/AAC on some Firefox ESR builds. Hardware/VA-API stays off.
for firefox_root in /usr/lib/firefox-esr /usr/lib/firefox; do
  pref_dir="$firefox_root/defaults/pref"
  if [[ -d "$pref_dir" ]]; then
    cat > "$pref_dir/droiddesk-media.js" <<'FIREFOX_PREFS'
pref("media.cubeb.sandbox", false);
pref("media.cubeb.backend", "pulse");
pref("layers.acceleration.disabled", true);
pref("gfx.webrender.software", true);
pref("gfx.canvas.accelerated", false);
pref("gfx.x11-egl.force-disabled", true);
pref("media.ffmpeg.enabled", true);
pref("media.rdd-ffmpeg.enabled", true);
pref("media.ffvpx.enabled", true);
pref("media.rdd-process.enabled", true);
pref("media.av1.enabled", false);
pref("media.ffmpeg.vaapi.enabled", false);
pref("media.hardware-video-decoding.enabled", false);
pref("media.mediasource.enabled", true);
pref("media.mediasource.webm.enabled", true);
pref("media.mediasource.webm.audio.enabled", true);
pref("media.mediasource.webm.video.enabled", true);
pref("media.mediasource.vp9.enabled", true);
pref("media.mediasource.mp4.enabled", true);
pref("media.mediasource.mp4.audio.enabled", true);
pref("media.mediasource.mp4.video.enabled", true);
pref("media.webm.enabled", true);
FIREFOX_PREFS
    chmod 0644 "$pref_dir/droiddesk-media.js"
  fi
done
if [[ -d /home/kali/.mozilla/firefox ]]; then
  while IFS= read -r -d '' profile_dir; do
    user_prefs="$profile_dir/user.js"
    touch "$user_prefs"
    while IFS= read -r pref_line; do
      pref_name="$(printf '%s' "$pref_line" | cut -d'"' -f2)"
      if grep -q "user_pref(\"$pref_name\"" "$user_prefs"; then
        sed -i "/^user_pref(\"$pref_name\"/d" "$user_prefs"
      fi
      printf '%s\n' "$pref_line" >> "$user_prefs"
    done <<'FIREFOX_USER_PREFS'
user_pref("media.cubeb.sandbox", false);
user_pref("media.cubeb.backend", "pulse");
user_pref("layers.acceleration.disabled", true);
user_pref("gfx.webrender.software", true);
user_pref("gfx.canvas.accelerated", false);
user_pref("gfx.x11-egl.force-disabled", true);
user_pref("media.ffmpeg.enabled", true);
user_pref("media.rdd-ffmpeg.enabled", true);
user_pref("media.ffvpx.enabled", true);
user_pref("media.av1.enabled", false);
user_pref("media.ffmpeg.vaapi.enabled", false);
user_pref("media.hardware-video-decoding.enabled", false);
user_pref("media.rdd-process.enabled", true);
user_pref("media.mediasource.enabled", true);
user_pref("media.mediasource.webm.enabled", true);
user_pref("media.mediasource.webm.audio.enabled", true);
user_pref("media.mediasource.webm.video.enabled", true);
user_pref("media.mediasource.vp9.enabled", true);
user_pref("media.mediasource.mp4.enabled", true);
user_pref("media.mediasource.mp4.audio.enabled", true);
user_pref("media.mediasource.mp4.video.enabled", true);
user_pref("media.webm.enabled", true);
FIREFOX_USER_PREFS
  done < <(find /home/kali/.mozilla/firefox -mindepth 1 -maxdepth 1 -type d -print0)
fi

# Record the actual Firefox/FFmpeg package and codec state for future diagnosis.
diagnostic_dir="/home/kali/.local/share/droiddesk"
install -d -m 0755 "$diagnostic_dir"
diagnostic_file="$diagnostic_dir/firefox-media-diagnostic.txt"
{
  echo "=== Firefox ==="
  firefox-esr --version 2>&1 || firefox --version 2>&1 || true
  dpkg-query -W firefox-esr ffmpeg 2>/dev/null || true
  echo "=== Firefox and codec package candidates ==="
  apt-cache policy firefox-esr libavcodec-extra62 libavcodec-extra63 2>/dev/null || true
  echo "=== Installed FFmpeg codec ABI alternatives ==="
  dpkg-query -W -f='${Status} ${Architecture}\\n' 'libavcodec-extra*' 2>/dev/null || true
  echo "=== FFmpeg libraries ==="
  dpkg-query -W 'libavcodec*' 2>/dev/null || true
  ldconfig -p 2>/dev/null | grep 'libavcodec.so' || true
  echo "=== Required software decoders ==="
  ffmpeg -hide_banner -decoders 2>/dev/null | grep -E ' (aac|h264|vp8|vp9|opus) ' || true
  echo "=== Firefox codec backend ==="
  find /usr/lib/firefox-esr /usr/lib/firefox -maxdepth 2 -name 'libmozavcodec.so' -type f -print 2>/dev/null || true
  echo "=== Firefox shared-library resolution ==="
  if [[ -f /usr/lib/firefox-esr/libxul.so ]]; then
    ldd /usr/lib/firefox-esr/libxul.so 2>&1 | grep -E 'not found|libavcodec|libavutil' || true
  fi
  echo "=== Active DroidDesk media preferences ==="
  grep -hE 'media\.(rdd-process|rdd-ffmpeg|ffvpx|ffmpeg|mediasource|webm|av1)' \
    /usr/lib/firefox-esr/defaults/pref/droiddesk-media.js \
    /home/kali/.mozilla/firefox/*/user.js 2>/dev/null || true
  echo "=== PulseAudio bridge ==="
  pactl info 2>&1 || true
  pactl list short sinks 2>&1 || true
  echo "=== Firefox ESR codec recommendations ==="
  apt-cache depends firefox-esr 2>&1 | grep -E 'Recommends:|^[[:space:]]+or ' | grep -E 'libavcodec|pulseaudio' || true
} > "$diagnostic_file"
chmod 0644 "$diagnostic_file"

# Build one flat XFCE gallery from every official Kali wallpaper package.
WALLPAPER_PACKAGES=(
  kali-wallpapers-2026 kali-wallpapers-2025 kali-wallpapers-2024
  kali-wallpapers-2023 kali-wallpapers-2022 kali-wallpapers-2020.4
  kali-wallpapers-2019.4 kali-wallpapers-legacy
)
install -d -m 0755 "$WALLPAPER_DIR"
# Remove links produced by the previous migration, then re-index every installed release.
find "$WALLPAPER_DIR" -maxdepth 1 -type l -delete
for package in "${WALLPAPER_PACKAGES[@]}"; do
  while IFS= read -r image_file; do
    [[ -f "$image_file" ]] || continue
    image_lower="$(printf '%s' "$image_file" | tr '[:upper:]' '[:lower:]')"
    case "$image_lower" in *.jpg|*.jpeg|*.png|*.webp|*.svg) ;; *) continue ;; esac
    image_name="$(basename "$image_file")"
    target="$WALLPAPER_DIR/$image_name"
    if [[ -e "$target" || -L "$target" ]]; then
      target="$WALLPAPER_DIR/$package-$image_name"
    fi
    [[ -e "$target" || -L "$target" ]] && continue
    ln -sfn "$image_file" "$target"
  done < <(dpkg-query -L "$package" 2>/dev/null || true)
done
wallpaper_count="$(find "$WALLPAPER_DIR" -maxdepth 1 \( -type f -o -type l \) | wc -l)"
echo "[Kali Linux] Official wallpaper choices exposed to XFCE: $wallpaper_count"

default_wallpaper="$WALLPAPER_DIR/kali-cubes2-16x9.jpg"
if [[ ! -f "$default_wallpaper" ]]; then
  default_wallpaper="$(find "$WALLPAPER_DIR" -maxdepth 1 \( -type f -o -type l \) -iname '*cubes2*' -print -quit || true)"
fi
if [[ -z "$default_wallpaper" ]]; then
  default_wallpaper="$(find "$WALLPAPER_DIR" -maxdepth 1 \( -type f -o -type l \) -print -quit || true)"
fi
if [[ -z "$default_wallpaper" || ! -f "$default_wallpaper" ]]; then
  echo "[Kali Linux] No official Kali wallpaper files were found after package installation."
  exit 21
fi

# Preserve existing XFCE preferences. Only add gallery/default keys when absent;
# never replace a user's selected wallpaper, panel style, compositing choice or icon layout.
desktop_xml="/home/kali/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml"
if [[ -f "$desktop_xml" ]]; then
  if ! grep -q 'name="image-path"' "$desktop_xml"; then
    sed -i '\#<property name="monitorbuiltin" type="empty">#a\                <property name="image-path" type="string" value="/usr/share/xfce4/backdrops/Kali Linux"/>' "$desktop_xml"
  fi
  if ! grep -q 'name="last-image"' "$desktop_xml"; then
    sed -i "/name=\"image-style\"/a\                  <property name=\"last-image\" type=\"string\" value=\"$default_wallpaper\"/>" "$desktop_xml"
  fi
  if ! grep -q 'name="show-trash"' "$desktop_xml"; then
    sed -i '/<property name="show-filesystem"/a\              <property name="show-trash" type="bool" value="true"/>' "$desktop_xml"
  fi
fi

# Add a transparent dock default only on first setup; don't overwrite user panel choices.
panel_xml="/home/kali/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-panel.xml"
if [[ -f "$panel_xml" ]] &&
   ! grep -q 'name="background-style"' "$panel_xml"; then
  sed -i '/<property name="panel-2" type="empty">/a\              <property name="background-style" type="uint" value="1"/>' "$panel_xml"
fi

# Add compositing only if XFCE has no saved choice yet.
xfwm_xml="/home/kali/.config/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml"
if [[ -f "$xfwm_xml" ]] &&
   ! grep -q 'name="use_compositing"' "$xfwm_xml"; then
  sed -i '/<property name="general" type="empty">/a\            <property name="use_compositing" type="bool" value="true"/>' "$xfwm_xml"
fi

# XFCE stores desktop icon coordinates in icons.screen*.rc; this migration never writes those files.

# Keep only XFCE's native Trash desktop icon; remove the duplicate custom shortcut.
rm -f /home/kali/Desktop/Trash.desktop

# Open downloaded .deb files in the installer; AppImages get menu + desktop launchers.
install -d -m 0755 /home/kali/.local/bin /home/kali/.local/share/applications
cat > /home/kali/.local/bin/droiddesk-install-download <<'INSTALLER'
#!/usr/bin/env bash
set -Eeuo pipefail
export HOME=/home/kali
export DEBIAN_FRONTEND=noninteractive
file="$1"
[[ -f "$file" ]] || exit 1
file="$(readlink -f "$file")"
lower_file="$(printf '%s' "$file" | tr '[:upper:]' '[:lower:]')"
log_dir="$HOME/.local/share/droiddesk"
install -d -m 0755 "$log_dir"
log_file="$log_dir/package-install.log"
exec >> >(tee -a "$log_file") 2>&1

show_failure() {
  message="$1"
  zenity --error --title='Installation failed' --width=480 --text="$message
Full details were saved to:
$log_file" 2>/dev/null || true
  diagnostic_file="$(mktemp)"
  tail -n 45 "$log_file" > "$diagnostic_file" 2>/dev/null || true
  zenity --text-info --title='Installer diagnostics' --filename="$diagnostic_file" --width=760 --height=520 2>/dev/null || true
  rm -f "$diagnostic_file"
}

case "$lower_file" in
  *.deb)
    if ! command -v dpkg-deb >/dev/null 2>&1; then
      show_failure "The Debian package tools are missing."
      exit 2
    fi
    deb_arch="$(dpkg-deb -f "$file" Architecture 2>/dev/null || true)"
    deb_name="$(dpkg-deb -f "$file" Package 2>/dev/null || true)"
    host_arch="$(dpkg --print-architecture 2>/dev/null || true)"
    if [[ -z "$deb_arch" || -z "$deb_name" ]]; then
      show_failure "This file is not a valid Debian package."
      exit 2
    fi
    if [[ "$deb_arch" != "all" && "$deb_arch" != "$host_arch" ]]; then
      echo "[DroidDesk Installer] The selected DEB is $deb_arch; Kali is $host_arch."
      echo "[DroidDesk Installer] Looking for the same application in Kali's ARM64 repositories."
      if sudo -n apt-get -o Acquire::ForceIPv4=true -o Acquire::Retries=3 -o Dpkg::Use-Pty=0 update; then
        candidate_arch="$(apt-cache show "$deb_name" 2>/dev/null |
          awk '/^Architecture:/ {
            if ($2 == "arm64") native=1
            else if ($2 == "all") common=1
          } END {
            if (native) print "arm64"
            else if (common) print "all"
          }')"
        if [[ "$candidate_arch" == "arm64" || "$candidate_arch" == "all" ]]; then
          package_spec="$deb_name"
          if [[ "$candidate_arch" == "arm64" ]]; then package_spec="$deb_name:arm64"; fi
          echo "[DroidDesk Installer] Installing compatible repository package $package_spec."
          if sudo -n apt-get -o Dpkg::Use-Pty=0 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold --no-install-recommends install -y "$package_spec"; then
            package_status="$(dpkg-query -W -f='${Status}' "$deb_name" 2>/dev/null || true)"
            if [[ "$package_status" == "install ok installed" ]]; then
              sudo -n update-desktop-database /usr/share/applications 2>/dev/null || true
              zenity --info --title='Kali Linux' --text="Installed the ARM64 repository build of $deb_name." 2>/dev/null || true
              exit 0
            fi
          fi
        fi
      fi
      related_candidates="$(apt-cache search --names-only "$deb_name" 2>/dev/null | head -n 8 || true)"
      echo "[DroidDesk Installer] Related Kali ARM64 repository matches:"
      printf '%s\n' "$related_candidates"
      show_failure "Wrong package architecture.
Package: $deb_arch
Kali system: $host_arch
This file is an AMD64 build and cannot execute as an ARM64 Linux program.
I checked Kali's repositories for an ARM64 build of $deb_name, but none was available under that package name.
Related repository matches are listed in package-install.log.
Open Add applications > Browse or Featured for compatible ARM64 alternatives.
If the publisher does not provide an ARM64 build, this exact download cannot be installed on this phone."
      exit 3
    fi

    echo "[DroidDesk Installer] Installing $deb_name ($deb_arch) from $file"
    echo "[DroidDesk Installer] Package control metadata:"
    dpkg-deb -f "$file" Package Version Architecture Depends 2>&1 || true
    echo "[DroidDesk Installer] Simulating dependency resolution before installation:"
    sudo -n apt-get -s install "$file" 2>&1 || true
    # Refresh package indexes, then let APT resolve the local package and
    # all dependencies from the configured Kali repositories.
    if ! sudo -n apt-get -o Acquire::ForceIPv4=true -o Acquire::Retries=3 -o Dpkg::Use-Pty=0 update; then
      echo "[DroidDesk Installer] APT update failed; attempting installation with cached indexes."
    fi

    install_ok=0
    if ! sudo -n dpkg --configure -a; then
      echo "[DroidDesk Installer] Repairing the previously interrupted dpkg transaction before this package."
      sudo -n apt-get -o Acquire::Retries=3 -o Dpkg::Use-Pty=0 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold --fix-broken install -y --no-install-recommends
      sudo -n dpkg --configure -a
    fi
    if sudo -n apt-get -o Dpkg::Use-Pty=0 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold --no-install-recommends install -y "$file"; then
      install_ok=1
    else
      echo "[DroidDesk Installer] APT local-file install failed; trying dpkg followed by dependency repair."
      sudo -n dpkg --configure -a || true
      sudo -n dpkg -i "$file" || true
      if sudo -n apt-get -o Acquire::Retries=3 -o Dpkg::Use-Pty=0 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold --fix-broken install -y --no-install-recommends; then
        install_ok=1
      fi
    fi

    package_status="$(dpkg-query -W -f='${Status}' "$deb_name" 2>/dev/null || true)"
    if [[ "$install_ok" -eq 1 && "$package_status" == "install ok installed" ]]; then
      sudo -n update-desktop-database /usr/share/applications 2>/dev/null || true
      sudo -n update-mime-database /usr/share/mime 2>/dev/null || true
      zenity --info --title='Kali Linux' --text="Installed $deb_name successfully. Find it in the Applications menu." 2>/dev/null || true
    else
      show_failure "Could not finish installing $deb_name.
Architecture: $deb_arch
System architecture: $host_arch
APT could not resolve or configure all dependencies."
      exit 1
    fi
    ;;
  *.appimage)
    app_arch="$(file -b "$file" 2>/dev/null || true)"
    echo "[DroidDesk Installer] AppImage file type: $app_arch"
    if ! printf '%s' "$app_arch" | grep -Eqi 'ARM aarch64|ARM64|AArch64'; then
      show_failure "This AppImage is not identified as ARM64/AArch64.
Detected file type: $app_arch
This Kali environment is ARM64. Download the ARM64 AppImage, not x86_64/AMD64."
      exit 3
    fi
    install -d "$HOME/Applications" "$HOME/.local/share/applications" "$HOME/Desktop"
    safe_file="$(basename "$file" | tr -cs '[:alnum:]._-' '_')"
    target="$HOME/Applications/$safe_file"
    cp -f "$file" "$target"
    chmod 0755 "$target"
    app_name="$(basename "$safe_file" .AppImage)"
    desktop="$HOME/.local/share/applications/$app_name.desktop"
    cat > "$desktop" <<ENTRY
[Desktop Entry]
Version=1.0
Type=Application
Name=$app_name
Exec=env APPIMAGE_EXTRACT_AND_RUN=1 "$target"
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
