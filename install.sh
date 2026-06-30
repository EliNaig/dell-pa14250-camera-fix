#!/usr/bin/env bash
#
# install.sh: Make the built-in camera fully work on a Dell Pro 14 Premium PA14250
#              (Intel Lunar Lake: IPU7 + OmniVision ov08x40 + Synaptics SVP7500 "CVS") on Fedora.
#              End to end: driver -> a normal /dev/video webcam that every app can use.
#
# Verified: Fedora 44, kernel 7.0.13-200, libcamera 0.7.1, BIOS 2.13.4 (2026-06-30).
# Result: GNOME Snapshot + Firefox/Chrome + Zoom/Teams/etc. all see one camera "IPU7-Camera".
#
# What it sets up:
#   1. intel_cvs (DKMS)      - CVS ownership handshake so the sensor can stream   [THE core fix]
#   2. v4l2loopback          - virtual webcam /dev/video42 labelled "IPU7-Camera"
#   3. ipu7-camera-bridge    - always-on root service: libcamera -> /dev/video42 (live feed)
#   4. udev rule             - raw IPU nodes locked to root (apps see only the one good camera)
#   5. WirePlumber rules     - one clean "IPU7-Camera" for PipeWire apps (Snapshot, browsers)
#
# Requirements: Fedora 41+, kernel >= 6.17.4, libcamera >= 0.5.2, latest Dell BIOS,
#   Secure Boot OFF (otherwise enroll the DKMS MOK key after install).
#
# Usage:  bash install.sh        (prompts for sudo password)
#
set -euo pipefail

LOOPBACK_NR=42
LOOPBACK_DEV="/dev/video${LOOPBACK_NR}"
SRC="${HOME}/vision-drivers"

# ---- 0. Hardware sanity check ------------------------------------------------
echo "==> Detecting hardware"
MODEL="$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo unknown)"
echo "    Laptop : ${MODEL}"
IPU_PCI="$(lspci -D 2>/dev/null | grep -iE 'IPU|Image Processing' | grep -i intel | head -1 | awk '{print $1}')"
if [ -z "${IPU_PCI}" ]; then
  echo "    !! Could not find an Intel IPU via lspci. This script targets Intel IPU6/IPU7 MIPI"
  echo "       cameras (Meteor/Lunar Lake). If you do not have one, this will not help. Aborting."
  exit 1
fi
echo "    IPU PCI: ${IPU_PCI}"
if ! lsmod | grep -q ov08x40; then
  echo "    NOTE: sensor 'ov08x40' not loaded. This script is tuned for ov08x40; other sensors"
  echo "          may need a different label, but the same overall approach applies."
fi
echo

# ---- 1. intel_cvs driver (vision-drivers) via DKMS ---------------------------
echo "==> [1/5] intel_cvs driver via DKMS"
sudo dnf install -y git make gcc dkms "kernel-devel-$(uname -r)"
if [ -d "${SRC}/.git" ]; then git -C "${SRC}" pull --ff-only || true
else git clone https://github.com/intel/vision-drivers.git "${SRC}"; fi
NAME="$(grep -oP 'PACKAGE_NAME=\K.*' "${SRC}/dkms.conf" | tr -d '"')"
VER="$(grep -oP 'PACKAGE_VERSION=\K.*' "${SRC}/dkms.conf" | tr -d '"')"
if ! dkms status | grep -q "${NAME}/${VER}"; then
  sudo rm -rf "/usr/src/${NAME}-${VER}"; sudo cp -r "${SRC}" "/usr/src/${NAME}-${VER}"
  sudo dkms add    -m "${NAME}" -v "${VER}" || true
  sudo dkms build  -m "${NAME}" -v "${VER}"
  sudo dkms install -m "${NAME}" -v "${VER}"
fi
echo intel_cvs | sudo tee /etc/modules-load.d/intel_cvs.conf >/dev/null
sudo modprobe intel_cvs 2>/dev/null || true

# ---- 2. v4l2loopback virtual webcam -----------------------------------------
echo "==> [2/5] v4l2loopback virtual webcam (${LOOPBACK_DEV} = IPU7-Camera)"
sudo dnf install -y "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm" || true
sudo dnf install -y akmod-v4l2loopback
sudo akmods --force --kernels "$(uname -r)" || true
echo '# shadow package default (OBS) to avoid card_label conflict' | sudo tee /etc/modprobe.d/98-v4l2loopback.conf >/dev/null
echo "options v4l2loopback devices=1 video_nr=${LOOPBACK_NR} exclusive_caps=1 card_label=\"IPU7-Camera\"" | sudo tee /etc/modprobe.d/v4l2-relayd.conf >/dev/null
sudo rm -f /etc/modprobe.d/ipu7-loopback.conf
echo v4l2loopback | sudo tee /etc/modules-load.d/v4l2loopback.conf >/dev/null
sudo modprobe -r v4l2loopback 2>/dev/null || true
sudo modprobe v4l2loopback

# ---- 3. udev: loopback perms + lock raw IPU nodes to root --------------------
echo "==> [3/5] udev rules (raw IPU nodes -> root only; loopback -> users)"
echo "KERNEL==\"video${LOOPBACK_NR}\", SUBSYSTEM==\"video4linux\", GROUP=\"video\", MODE=\"0660\", TAG+=\"uaccess\"" \
  | sudo tee /etc/udev/rules.d/70-ipu7-loopback.rules >/dev/null
echo "SUBSYSTEM==\"video4linux\", KERNELS==\"${IPU_PCI}\", TAG-=\"uaccess\", GROUP=\"root\", MODE=\"0660\"" \
  | sudo tee /etc/udev/rules.d/99-ipu7-hide-raw.rules >/dev/null
sudo udevadm control --reload-rules
sudo udevadm trigger -s video4linux || true

# ---- 4. always-on bridge service (root: libcamera -> loopback) ---------------
echo "==> [4/5] always-on bridge service"
sudo systemctl disable --now v4l2-relayd.service 'v4l2-relayd@*.service' 2>/dev/null || true
sudo tee /etc/systemd/system/ipu7-camera-bridge.service >/dev/null <<EOF
[Unit]
Description=IPU7 libcamera always-on bridge to v4l2loopback (IPU7-Camera)
After=systemd-logind.service
Wants=modprobe@v4l2loopback.service

[Service]
ExecStartPre=/bin/sh -c 'until [ -e ${LOOPBACK_DEV} ]; do sleep 0.5; done'
ExecStart=/usr/bin/gst-launch-1.0 -e libcamerasrc ! queue ! videoconvert ! videoscale ! video/x-raw,format=YUY2,width=1280,height=720 ! v4l2sink device=${LOOPBACK_DEV} sync=false
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now ipu7-camera-bridge.service

# ---- 5. WirePlumber: one clean camera for PipeWire apps ----------------------
echo "==> [5/5] WirePlumber rules"
WPD="${HOME}/.config/wireplumber/wireplumber.conf.d"; mkdir -p "${WPD}"
cat > "${WPD}/51-disable-libcamera.conf" <<'EOF'
# Raw libcamera source cannot negotiate via GstCameraBin on this stack; use the loopback instead.
wireplumber.profiles = { main = { monitor.libcamera = disabled } }
EOF
cat > "${WPD}/52-hide-ipu7-raw.conf" <<'EOF'
# Hide the raw Intel IPU (isys) capture nodes; keep only the v4l2loopback "IPU7-Camera".
monitor.v4l2.rules = [
  { matches = [ { api.v4l2.cap.driver = "isys" } ]
    actions = { update-props = { node.disabled = true } } }
]
EOF
systemctl --user restart wireplumber || true

echo
echo "================================================================"
echo "DONE.  Reboot to confirm everything auto-starts, then test:"
echo "  ffmpeg -f v4l2 -i ${LOOPBACK_DEV} -frames:v 1 /tmp/cam.jpg && xdg-open /tmp/cam.jpg"
echo "  ...or GNOME Snapshot, or a browser at webcamtests.com (pick 'IPU7-Camera')."
echo
echo "If Secure Boot is ON, enroll the DKMS key once: sudo mokutil --import /var/lib/dkms/mok.pub"
echo "Heads-up: always-on feed => the camera privacy LED stays on while logged in."
echo "================================================================"
