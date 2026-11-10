#!/usr/bin/env bash
set -Eeuo pipefail
export HOME=/root USER=root LOGNAME=root
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export LANG=C.UTF-8 BASH_ENV=/dev/null
MARKER=/root/.droiddesk/xfce-applications-menu-v1
SESSION_ADDRESS_FILE=/home/kali/.local/share/droiddesk/dbus-session-address
ICON_DIR=/usr/share/icons/hicolor/scalable/apps

if [[ "${1:-}" == "--self-test" ]]; then
  sample_output=$'Value is an array with 3 items:\n    int 20\n    int 21\n    int 23'
  parsed_ids="$(printf '%s\n' "$sample_output" | sed -nE 's/^[[:space:]]*(int[[:space:]]+)?([0-9]+)[[:space:]]*$/\2/p' | xargs)"
  [[ "$parsed_ids" == "20 21 23" ]]
  echo "[DroidDesk Panel] xfconf-query integer-array parser test passed."
  exit 0
fi

install -d -m 0700 /root/.droiddesk "$ICON_DIR"
cat > "$ICON_DIR/droiddesk-kali-menu.svg" <<'MENU_ICON'
<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24">
  <g fill="#ffffff" stroke="#10233f" stroke-width="1.25">
    <circle cx="7" cy="7" r="3.1"/>
    <circle cx="17" cy="7" r="3.1"/>
    <circle cx="7" cy="17" r="3.1"/>
    <circle cx="17" cy="17" r="3.1"/>
  </g>
</svg>
MENU_ICON
chmod 0644 "$ICON_DIR/droiddesk-kali-menu.svg"
gtk-update-icon-cache -f -t /usr/share/icons/hicolor >/dev/null 2>&1 || true

if [[ ! -s "$SESSION_ADDRESS_FILE" ]]; then
  echo "[DroidDesk Panel] XFCE D-Bus address is not ready; no success marker was written."
  exit 10
fi
session_address="$(cat "$SESSION_ADDRESS_FILE")"
if ! sudo -E -u kali env DISPLAY=:0 XDG_RUNTIME_DIR=/tmp/runtime-kali DBUS_SESSION_BUS_ADDRESS="$session_address" /bin/bash -s <<'PANEL'
set -Eeuo pipefail
channel=xfce4-panel
panel_path=/panels/panel-2/plugin-ids
xfconf-query -c "$channel" -p /panels/panel-2/position >/dev/null
current_ids="$(xfconf-query -c "$channel" -p "$panel_path" 2>/dev/null |
  sed -nE 's/^[[:space:]]*(int[[:space:]]+)?([0-9]+)[[:space:]]*$/\2/p' | xargs)"
menu_id=""
for id in $current_ids; do
  plugin="$(xfconf-query -c "$channel" -p "/plugins/plugin-$id" 2>/dev/null || true)"
  if [[ "$plugin" == *applicationsmenu* ]]; then menu_id="$id"; break; fi
done
if [[ -z "$menu_id" ]]; then
  for candidate in $(seq 25 250); do
    if ! xfconf-query -c "$channel" -p "/plugins/plugin-$candidate" >/dev/null 2>&1; then
      menu_id="$candidate"; break
    fi
  done
  [[ -n "$menu_id" ]] || { echo "No free XFCE panel plugin ID"; exit 3; }
  xfconf-query -c "$channel" -p "/plugins/plugin-$menu_id" --create --type string --set applicationsmenu
  args=(xfconf-query -c "$channel" -p "$panel_path" --force-array --type int --set "$menu_id")
  for id in $current_ids; do args+=(--type int --set "$id"); done
  "${args[@]}"
fi
xfconf-query -c "$channel" -p "/plugins/plugin-$menu_id/show-button-title" --create --type bool --set false
xfconf-query -c "$channel" -p "/plugins/plugin-$menu_id/button-title" --create --type string --set Applications
xfconf-query -c "$channel" -p "/plugins/plugin-$menu_id/button-icon" --create --type string --set droiddesk-kali-menu
xfconf-query -c "$channel" -p "/plugins/plugin-$menu_id/show-menu-icons" --create --type bool --set true
xfce4-panel --restart
sleep 1
plugin="$(xfconf-query -c "$channel" -p "/plugins/plugin-$menu_id" 2>/dev/null)"
ids="$(xfconf-query -c "$channel" -p "$panel_path" 2>/dev/null |
  sed -nE 's/^[[:space:]]*(int[[:space:]]+)?([0-9]+)[[:space:]]*$/\2/p' | xargs)"
[[ "$plugin" == *applicationsmenu* ]] || exit 4
[[ " $ids " == *" $menu_id "* ]] || exit 5
echo "[DroidDesk Panel] Verified Applications menu plugin $menu_id on bottom panel 2."
PANEL
then
  echo "[DroidDesk Panel] XFCE menu configuration failed; retrying on next desktop launch."
  exit 11
fi

touch "$MARKER"
chmod 0600 "$MARKER"
echo "[DroidDesk Panel] Four-dot Applications menu repair succeeded."
