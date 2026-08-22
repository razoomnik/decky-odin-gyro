# Odin Gyro

Decky Loader plugin for **AYN Odin 3** running **Armada**.

It provides two actions directly from Decky:

1. **Install / Update Gyro Fix** — installs or rebuilds the Odin 3 SSC/IIO gyro fix for the kernel in the current Armada deployment.
2. **Calibrate Gyro** — restarts the sensor stack, performs a stationary zero-bias calibration, then reconnects InputPlumber.

## Features

- Uses the bundled tested gyro recovery script.
- Rebuilds `sns_iio.ko` when Armada changes the kernel ABI.
- Starts `adsprpcd` and `snsfeed` through `odin3-sensors.service`.
- Integrates `bmi323-imu` with InputPlumber.
- Applies the correct accelerometer mount matrix for automatic screen rotation.
- Runs recovery in the background so the Decky UI stays responsive.
- Shows live gyro-path status and a terminal-style live recovery console.
- Shows a clear 4-step calibration progress view with percentage and instructions.

## Install

Download the latest ready-to-install ZIP from `release/` and install it through Decky Loader.

Current package:

```text
release/OdinGyro-v0.1.14.zip
```

### Manual install on Armada

Extract the source repository and run:

```bash
chmod +x install-manual.sh
./install-manual.sh
```

## Calibration

Start **Calibrate Gyro** and follow the on-screen status. The plugin displays four stages:

1. Starting the gyro sensor.
2. Capturing the zero-bias calibration. **Keep Odin completely still.**
3. Restarting InputPlumber. Once the zero point is captured, Odin may be moved.
4. Verifying the full Steam gyro path.

The progress card shows the current step, percentage, current operation, and whether Odin must remain still.

## Requirements

- AYN Odin 3
- Armada
- Decky Loader
- Internet access when rebuilding the gyro fix after an Armada/kernel update

The plugin requires Decky's `root` flag because gyro recovery installs a kernel module and manages system services.

## Development

Frontend source: `src/index.tsx`  
Backend: `main.py`  
Bundled recovery script: `scripts/odin3-gyro-recovery.sh`

Build:

```bash
npm install
npm run build
```

## Tested

The recovery flow is designed for AYN Odin 3 across Armada kernel updates. Decky's backend kernel identity is intentionally ignored during recovery. The target comes from the exact kernel source pinned by the current Armada deployment, and the module's own `vermagic` determines the installation directory.

## v0.1.14

- Resolves the installed Armada kernel artifacts through a native transient systemd unit instead of Decky's/FEX filesystem view.
- Matches the host `.armada-source` marker by its `Source: linux-...` token and copies the exact installed `vmlinuz` plus a stock module into the recovery workspace.
- Keeps the exact-config/BTF build path introduced in v0.1.13.
- Bundled recovery script updated to v1.0.14.

## v0.1.13

- Extracts the exact kernel config from the installed Armada `vmlinuz`.
- Preserves `CONFIG_DEBUG_INFO_BTF`, `CONFIG_DEBUG_INFO_BTF_MODULES`, and other ABI-affecting options while preparing the external-module build.
- Compares `.gnu.linkonce.this_module` size against a stock Armada module before installation.
- Kernel-module cache remains keyed by the exact `armada-packages` commit.
- Recovery prints service and kernel rejection diagnostics directly in the Decky terminal on failure.
- Bundled recovery script updated to v1.0.13.

## v0.1.11

- Removes the Kernel row from Decky status.
- Stops reading or validating any kernel release from the Decky backend.
- Resolves the exact `armada-packages` commit from the current Armada deployment.
- Builds `sns_iio.ko` from that deployment's pinned kernel source.
- Uses the built module's own `vermagic` as the authoritative installation target, e.g. `/var/lib/odin3-gyro/modules/7.2.0-rc7/sns_iio.ko`.
- Keeps RC normalization only for validating the built module against Armada source metadata such as `7.2-rc7` vs `7.2.0-rc7`.
- Prevents an older recovery script downloaded from GitHub from replacing a newer bundled recovery.
- Bundled recovery script updated to v1.0.11.

## v0.1.6

- Replaced the tiny recovery output preview with a terminal-style live console.
- Streams recovery output while the kernel module is being rebuilt and installed.
- Shows the current recovery stage parsed from `==>` lines.
- Shows RUNNING / exit status and elapsed recovery time.
- Auto-scrolls to the newest output while retaining a much larger rolling log.
- Keeps the completed/failed terminal visible after recovery so the failure point can be inspected.
- Clarifies that recovery continues in the Decky backend if the Quick Access panel is closed.

## v0.1.5

- Added live four-stage calibration progress.
- Added progress percentage and current operation.
- Added prominent **KEEP ODIN STILL** instruction during zero calibration.
- After zero capture, the UI explicitly says Odin may be moved while InputPlumber reconnects.
- Increased status polling during calibration for smoother feedback.

## License

MIT
