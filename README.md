# Dell Pro 14 Premium (PA14250) camera fix for Linux / Fedora

Makes the built-in webcam work on the **Dell Pro 14 Premium PA14250** (Intel Lunar Lake) on Fedora.
After running it, the camera works in GNOME Snapshot, Firefox, Chrome, Zoom, Teams, and more.

The camera works on Windows but looks dead on Linux until this is set up. This repo automates the
whole fix.

**Status:** verified working on Fedora 44, kernel 7.0.13-200, libcamera 0.7.1, BIOS 2.13.4.

## Disclaimer

Use at your own risk. The installer builds an out-of-tree kernel driver, changes system config, and
needs sudo. It worked on the setup under "Status," but hardware and firmware vary. Read the scripts
before running them. The author is not responsible for any damage. See the [LICENSE](./LICENSE).

## Quick start

```bash
git clone https://github.com/EliNaig/dell-pa14250-camera-fix.git
cd dell-pa14250-camera-fix
bash install.sh
sudo reboot
```

Test it after rebooting:

```bash
ffmpeg -f v4l2 -i /dev/video42 -frames:v 1 /tmp/cam.jpg && xdg-open /tmp/cam.jpg
```

You should see a real photo. GNOME Snapshot and `webcamtests.com` should also work (pick the camera
named **IPU7-Camera**). To undo everything, run `bash uninstall.sh`.

## Does this apply to you?

This is for Intel IPU6 / IPU7 MIPI cameras behind an Intel CVS chip, common on Meteor Lake and Lunar
Lake Dell laptops with the `ov08x40` sensor. Check with:

```bash
lspci | grep -i ipu                   # an Intel IPU?
lsusb | grep -i 06cb                  # Synaptics CVS bridge (06cb:0701)?
sudo dnf install -y libcamera-tools && cam --list
```

If `cam --list` says "No sensor found" while the sensor shows up in the kernel, you are missing the
`intel_cvs` driver, which is what this installs.

## What it does

The camera is an Intel IPU7 MIPI sensor (`ov08x40`) whose power and control run through a Synaptics
CVS chip (`06cb:0701`). The sensor is detected but will not stream until Intel's `intel_cvs` driver
(not in the mainline kernel) does a "transfer of ownership" handshake. The installer sets up:

* **`intel_cvs`** built with DKMS. The core fix; lets the sensor stream via libcamera.
* **`v4l2loopback`** virtual webcam `/dev/video42` named "IPU7-Camera". A normal webcam node apps understand.
* **`ipu7-camera-bridge.service`**. An always-on root service piping libcamera into the loopback.
* **A udev rule** locking the raw IPU nodes to root, so apps see only the one good camera.
* **WirePlumber rules** presenting a single clean "IPU7-Camera" to PipeWire apps.

The feed is always on (the simpler on-demand `v4l2-relayd` approach was unreliable here), so the
camera privacy LED stays on while you are logged in.

## Requirements

* Kernel 6.17.4+ and libcamera 0.5.2+ (both met on Fedora 44).
* Latest Dell BIOS recommended.
* Secure Boot off. If it is on, enroll the DKMS key once: `sudo mokutil --import /var/lib/dkms/mok.pub`.

DKMS rebuilds `intel_cvs` automatically on kernel updates. If a build ever fails, run
`git -C ~/vision-drivers pull && bash install.sh`.

## Troubleshooting

* **`cam --list` says "No sensor found".** `intel_cvs` is not loaded. Check `lsmod | grep intel_cvs`
  and `sudo dmesg | grep -i ownership`, then re-run `bash install.sh`.
* **No frames / bridge restarting.** Check `systemctl status ipu7-camera-bridge` and confirm
  `/dev/video42` exists (`v4l2-ctl --list-devices`).
* **App lists many raw `ipu7` cameras.** The udev lock did not apply; confirm `ls -l /dev/video0` is
  `root root`, then `sudo udevadm trigger` or reboot.
* **Browser says "no camera".** Fully quit and reopen it. If needed, enable PipeWire camera (Chrome:
  `chrome://flags/#enable-webrtc-pipewire-camera`; Firefox: `media.webrtc.camera.allow-pipewire`).
* **Washed out or odd colors.** Uncalibrated libcamera tuning. Cosmetic only.

## References

* [Red Hat Bug 2377621: ipu7 + ov08x40 needs vision-drivers](https://bugzilla.redhat.com/show_bug.cgi?id=2377621)
* [intel/vision-drivers](https://github.com/intel/vision-drivers) and [issue #36](https://github.com/intel/vision-drivers/issues/36)
* [intel/ipu6-drivers issue #426: Synaptics SVP7500 bulk failures](https://github.com/intel/ipu6-drivers/issues/426)

## Hardware

| Item | Value |
|------|-------|
| Laptop | Dell Pro 14 Premium PA14250 (Lunar Lake, Core Ultra 7 266V) |
| Camera | Intel IPU7 + OmniVision ov08x40 (OVTI08F4) MIPI CSI-2 |
| CVS bridge | Synaptics SVP7500 (USB `06cb:0701`), ACPI `INTC10DE` |
| Fix | `intel_cvs` from intel/vision-drivers, via DKMS |
