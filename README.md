# Odin Gyro

Decky Loader plugin for **AYN Odin 3** running **Armada**.

It provides two actions directly from Decky:

1. **Install / Update Gyro Fix** — installs or rebuilds the Odin 3 SSC/IIO gyro fix for the currently running Armada kernel.
2. **Calibrate Gyro** — restarts the sensor stack and performs a stationary zero-bias calibration before restarting InputPlumber.

## Features

- Detects the current Armada kernel.
- Uses the bundled tested gyro recovery script.
- Rebuilds `sns_iio.ko` when Armada changes the kernel ABI.
- Starts `adsprpcd` and `snsfeed` through `odin3-sensors.service`.
- Integrates `bmi323-imu` with InputPlumber.
- Applies the correct accelerometer mount matrix for automatic screen rotation.
- Runs recovery in the background so the Decky UI stays responsive.
- Shows gyro status and recent recovery output.

## Install

Download the latest ready-to-install ZIP from `release/` and install it through Decky Loader.

Current package:

```text
release/OdinGyro-v0.1.0.zip
```

### Manual install on Armada

If ZIP installation through Decky is unavailable:

```bash
unzip OdinGyro-v0.1.0-source.zip
cd OdinGyro-src
chmod +x install-manual.sh
./install-manual.sh
```

## Calibration

Place the Odin 3 on a stable surface and do not move it while calibration is running.

The plugin:

1. restarts `odin3-sensors.service`;
2. waits until `snsfeed` is actually running;
3. leaves the device stationary during the zero-bias sampling window;
4. restarts InputPlumber.

## Requirements

- AYN Odin 3
- Armada
- Decky Loader
- Internet access when rebuilding the gyro fix after an Armada/kernel update

The plugin requires Decky's `_root` flag because gyro recovery installs a kernel module and manages system services.

## Development

Frontend source:

```text
src/index.tsx
```

Backend:

```text
main.py
```

Bundled recovery script:

```text
scripts/odin3-gyro-recovery.sh
```

Build:

```bash
npm install
npm run build
```

## Tested

The bundled recovery flow was verified on AYN Odin 3 with Armada Linux 7.1.5 after an Armada update invalidated the previous `sns_iio.ko` build.

## License

MIT
