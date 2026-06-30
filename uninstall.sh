#!/usr/bin/env bash
# uninstall.sh: undo everything install.sh set up (does NOT remove BIOS/kernel updates).
set -uo pipefail

echo "==> Stopping & removing the always-on bridge"
sudo systemctl disable --now ipu7-camera-bridge.service 2>/dev/null || true
sudo rm -f /etc/systemd/system/ipu7-camera-bridge.service
sudo systemctl daemon-reload

echo "==> Removing udev rules"
sudo rm -f /etc/udev/rules.d/70-ipu7-loopback.rules /etc/udev/rules.d/99-ipu7-hide-raw.rules
sudo udevadm control --reload-rules

echo "==> Removing v4l2loopback config (leaves the package installed)"
sudo rm -f /etc/modprobe.d/98-v4l2loopback.conf /etc/modprobe.d/v4l2-relayd.conf /etc/modules-load.d/v4l2loopback.conf
sudo modprobe -r v4l2loopback 2>/dev/null || true

echo "==> Removing WirePlumber rules"
rm -f "${HOME}/.config/wireplumber/wireplumber.conf.d/51-disable-libcamera.conf" \
      "${HOME}/.config/wireplumber/wireplumber.conf.d/52-hide-ipu7-raw.conf"
systemctl --user restart wireplumber 2>/dev/null || true

echo "==> Removing intel_cvs DKMS module + autoload"
sudo rm -f /etc/modules-load.d/intel_cvs.conf
NAME="$(grep -oP 'PACKAGE_NAME=\K.*' "${HOME}/vision-drivers/dkms.conf" 2>/dev/null | tr -d '"' || echo vision-driver)"
VER="$(grep -oP 'PACKAGE_VERSION=\K.*' "${HOME}/vision-drivers/dkms.conf" 2>/dev/null | tr -d '"' || echo 1.0.0)"
sudo dkms remove -m "${NAME}" -v "${VER}" --all 2>/dev/null || true
sudo modprobe -r intel_cvs 2>/dev/null || true

echo "Done. Reboot recommended. (intel_cvs source stays in ~/vision-drivers; v4l2loopback/v4l2-relayd packages remain installed.)"
