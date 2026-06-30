# Dell Pro 14 Premium (PA14250) camera fix for Linux / Fedora

Get the built-in webcam working on a **Dell Pro 14 Premium PA14250** (Intel **Lunar Lake**, Core
Ultra 7 266V) on Fedora. After this, the camera works in every app: GNOME Snapshot, Firefox,
Chrome, Zoom, Teams, Discord, and OBS.

The camera works on Windows but looks dead on Linux until you set it up. This repo automates the
whole fix.

**Status:** verified working on Fedora 44, kernel 7.0.13-200, libcamera 0.7.1, BIOS 2.13.4
(2026-06-30).

## Disclaimer

Use at your own risk. These scripts install an out-of-tree kernel driver, change system
configuration, and require sudo. They worked on the exact setup listed under "Status," but hardware
and firmware vary between machines. Please read what the scripts do before running them. The author
is not responsible for any damage. See the [LICENSE](./LICENSE) for the full no-warranty terms.

## Quick start

```bash
git clone https://github.com/EliNaig/dell-pa14250-camera-fix.git
cd dell-pa14250-camera-fix
bash install.sh
sudo reboot
```

After the reboot, test it:

```bash
ffmpeg -f v4l2 -i /dev/video42 -frames:v 1 /tmp/cam.jpg && xdg-open /tmp/cam.jpg
```

You should see a real photo. You can also open GNOME Snapshot, or visit `webcamtests.com` in a
browser and pick the camera named **IPU7-Camera**.

To undo everything, run `bash uninstall.sh`.

## Does this apply to you?

This fix is for **Intel IPU6 / IPU7 MIPI cameras that sit behind an Intel CVS chip**, common on
Meteor Lake and Lunar Lake era Dell laptops (especially the `ov08x40` sensor). Run these checks:

```bash
lspci | grep -i ipu                   # an Intel "IPU" Image Processing Unit?
lsmod | grep -E 'ov08x40|intel_ipu'   # MIPI sensor and IPU driver loaded?
lsusb | grep -i 06cb                  # Synaptics CVS bridge (06cb:0701 SVP7500)?
sudo dnf install -y libcamera-tools && cam --list
```

If `cam --list` reports **"No sensor found"** even though the sensor shows up in the kernel, you are
almost certainly missing the `intel_cvs` driver, which is exactly what this repo installs. Other
sensors (such as ov02c10) follow the same pattern; you may only need to change the camera label.

## Why the camera does not work out of the box

It is **not** a USB webcam. It is an Intel **IPU7** MIPI camera:

1. The sensor (`ov08x40`, ACPI `OVTI08F4`) connects over a CSI-2 link into the IPU7.
2. Its power, I2C, and GPIO lines are owned at boot by a **Synaptics SVP7500** chip
   (USB `06cb:0701`), which is an Intel **CVS** (Computer Vision Sensing) controller.

On a current Fedora the sensor is detected, but it will not stream, because the CVS chip never
hands control of the camera to the host. The missing piece is Intel's **`intel_cvs`** driver, from
[intel/vision-drivers](https://github.com/intel/vision-drivers). It is not in the mainline kernel.
Once loaded, it performs the "Transfer of ownership" handshake and the camera streams through
libcamera's software ISP.

## What the installer sets up

| Layer | Component | Purpose |
|-------|-----------|---------|
| Driver | `intel_cvs` built with DKMS | Performs the CVS ownership handshake so the sensor can stream. This is the core fix. |
| Virtual camera | `v4l2loopback` device `/dev/video42` named "IPU7-Camera" | A standard webcam node that every app understands. |
| Bridge | `ipu7-camera-bridge.service` (root, always on) | Continuously pipes libcamera into `/dev/video42`. |
| Permissions | A udev rule | Locks the raw IPU nodes (`/dev/video0` through `/dev/video31`) to root so apps see only the one good camera. |
| PipeWire | Two WirePlumber rules | Present a single clean "IPU7-Camera" to PipeWire apps such as Snapshot and browsers. |

### Why the feed is always on

An on-demand approach using `v4l2-relayd` (which would light the privacy LED only during calls) was
tried first, but it proved unreliable on this hardware: with `exclusive_caps`, the loopback
disappeared from apps whenever it was idle, so browsers and Snapshot reported "no camera." The
always-on bridge keeps a live feed so every app reliably finds the camera. The trade-off is that the
camera privacy LED stays on the whole time you are logged in. Making the on-demand path reliable
again would mean getting `v4l2-relayd`'s splash and visibility handling working correctly.

## Requirements

* Kernel 6.17.4 or newer, and libcamera 0.5.2 or newer (both are satisfied on Fedora 44).
* The latest Dell BIOS (the PA14250 was on 2.13.4). The `int3472` and GPIO firmware warnings you may
  see at boot are harmless once `intel_cvs` owns the camera.
* Secure Boot turned off. If Secure Boot is on, enroll the DKMS signing key once after installing:
  `sudo mokutil --import /var/lib/dkms/mok.pub`.

## Maintenance

* DKMS rebuilds `intel_cvs` automatically when the kernel updates, so there is usually nothing to do.
* If a kernel update ever breaks the build, refresh the source and re-run the installer:
  `git -C ~/vision-drivers pull && bash install.sh`.

## Troubleshooting

* **`cam --list` says "No sensor found" after install.** `intel_cvs` is not loaded. Check
  `lsmod | grep intel_cvs` and `sudo dmesg | grep -i ownership` (you want "Transfer of ownership
  success"). Re-run `bash install.sh`.
* **The bridge keeps restarting or there are no frames.** Check
  `systemctl status ipu7-camera-bridge` and `journalctl -u ipu7-camera-bridge -b`. Confirm
  `/dev/video42` exists with `v4l2-ctl --list-devices`.
* **An app still lists 30 or more raw `ipu7` cameras.** The udev lock did not apply. Confirm
  `ls -l /dev/video0` shows `root root` (not `root video`), then run `sudo udevadm trigger` or reboot.
* **A browser says "no camera found."** Fully quit and reopen the browser to clear its device cache.
  If it persists, enable PipeWire camera support. Chrome:
  `chrome://flags/#enable-webrtc-pipewire-camera`. Firefox: in `about:config`, set
  `media.webrtc.camera.allow-pipewire` to `true`.
* **The picture looks washed out or has odd colors.** This is the uncalibrated libcamera image
  pipeline (there is no `ov08x40.yaml` tuning file upstream yet). It is cosmetic and does not affect
  whether the camera works.

## How to verify it is working

```bash
# 1. A direct frame grab should produce a real photo
ffmpeg -f v4l2 -i /dev/video42 -frames:v 1 /tmp/cam.jpg && xdg-open /tmp/cam.jpg

# 2. PipeWire should list exactly one camera source: IPU7-Camera
wpctl status | sed -n '/Sources:/,/Filters/p'

# 3. GNOME Snapshot shows live video; webcamtests.com works in a browser
```

## References

* [Red Hat Bug 2377621: Dell Pro ipu7 + ov08x40 camera needs vision-drivers](https://bugzilla.redhat.com/show_bug.cgi?id=2377621)
* [intel/vision-drivers](https://github.com/intel/vision-drivers) and [issue #36 on why intel_cvs is critical for IPU7](https://github.com/intel/vision-drivers/issues/36)
* [intel/ipu6-drivers issue #426: Synaptics SVP7500 usbio-bridge bulk failures](https://github.com/intel/ipu6-drivers/issues/426)

## Hardware summary

| Item | Value |
|------|-------|
| Laptop | Dell Pro 14 Premium PA14250 (Lunar Lake, Core Ultra 7 266V) |
| Camera | Intel IPU7 with OmniVision ov08x40 (OVTI08F4) MIPI CSI-2 sensor |
| CVS bridge | Synaptics SVP7500 (USB `06cb:0701`), ACPI CVS device `INTC10DE` |
| Fix driver | `intel_cvs` from intel/vision-drivers, installed with DKMS |
