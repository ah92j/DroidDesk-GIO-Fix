#!/bin/bash
set -Eeuo pipefail

export HOME=/root
export USER=root
export LOGNAME=root
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export LANG=C.UTF-8
export TERM=xterm-256color
export DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none

echo "[DroidDesk Kali] Updating package indexes..."
apt-get update

echo "[DroidDesk Kali] Installing the Kali default toolset and XFCE..."
apt-get \
  -o Dpkg::Options::=--force-confdef \
  -o Dpkg::Options::=--force-confold \
  install -y \
  kali-linux-default \
  xfce4 \
  xfce4-terminal \
  dbus-x11 \
  xclip \
  x11-utils \
  papirus-icon-theme \
  fonts-noto-core

echo "[DroidDesk Kali] Verifying the requested package set..."
dpkg-query -W -f='${Status}' kali-linux-default | grep -qx 'install ok installed'
test -x /usr/bin/startxfce4
test -x /usr/bin/dbus-launch
test -x /usr/bin/xfce4-session

echo "[DroidDesk Kali] Package installation and verification completed."
