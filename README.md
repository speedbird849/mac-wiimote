# MacWiimote

A macOS userspace driver and bridge that connects a physical Nintendo Wii Remote (and attached Nunchuk) over Bluetooth and exposes it as a standard virtual USB HID Gamepad via Apple's `CoreHID.HIDVirtualDevice` framework.

## Features

- Virtual USB Gamepad: Exposes standard Generic Desktop Gamepad (`Usage Page 0x01, Usage 0x05`) with 16 digital buttons and 11 analog axes.
- Deterministic Calibration: Uses fixed midpoints and 1G scale constants across connections. Controller angle at connection time does not drift or skew calibration.
- Dynamic Nunchuk Hotplug: Detects insertion and removal at runtime via hardware status packets (Report `0x20`), seamlessly switching between standalone and extension reporting modes.
- Full Nunchuk Support: Translates analog joystick, C and Z buttons, and 10-bit 3-axis accelerometer data.
- Bidirectional Rumble: Intercepts standard HID force-feedback output reports from macOS and forwards them directly to the Wiimote motor.

## Technical Overview

### Virtual HID Report Descriptor
- Buttons: 16 digital buttons (Buttons 1-11 map to Wiimote inputs; Buttons 12 and 13 map to Nunchuk C and Z).
- Analog Axes (16-bit signed, -32768 to 32767):
  - Axis 0 (X): Primary Stick X (Nunchuk Stick X, or Wiimote tilt X fallback)
  - Axis 1 (Y): Primary Stick Y (Nunchuk Stick Y, or Wiimote tilt Y fallback)
  - Axis 2-4 (Z, Rx, Ry): Wiimote Accel X, Y, Z
  - Axis 5-7 (Rz, Slider, Dial): Gyro Pitch, Roll, Yaw
  - Axis 8-10 (Vx, Vy, Vz): Nunchuk Accel X, Y, Z

### Wiimote Hardware Protocol
- Device Matching: Matches `IOHIDDevice` with Vendor ID `0x057E` and Product ID `0x0306` (Nintendo RVL-CNT-01).
- Extension Detection: Listens for Input Report `0x20` (Status Report). Bit 1 of byte 3 (`data[3] & 0x02`) authoritatively indicates whether an expansion device is physically connected.
- Extension Handshake: On insertion, registers are configured over I2C to disable encryption (`0x55` to `0xA400F0`, `0x00` to `0xA400FB`), followed by continuous Report Mode `0x35` (Buttons + Accelerometer + 16 Extension Bytes). On removal, the driver reverts to Mode `0x31` (Buttons + Accelerometer).
- Nunchuk Packet Decoding: 
  - Stick: Bytes 6 and 7 (`SX`, `SY`), centered with a deadzone of +/-6.
  - Buttons: Byte 11 bit 1 (Button C) and bit 0 (Button Z), active-low.
  - Accelerometer: 10-bit resolution composed of upper 8 bits in bytes 8-10 and lower 2 bits packed into byte 11.

## Prerequisites

- macOS 13 or later (Apple Silicon or Intel).
- The `com.apple.developer.hid.virtual.device` entitlement is restricted by Apple. Running binaries with this entitlement on standard systems requires disabling System Integrity Protection (SIP) or setting `amfi_get_out_of_my_way=1` nvram boot argument, unless signed with an Apple-approved Developer ID provisioning profile.
- A physical Nintendo Wii Remote paired via Bluetooth (using WiiMotePair or standard Bluetooth settings).

## Building and Running

1. Compile the project:
   ```bash
   swift build
   ```

2. Sign the binary with the required virtual device entitlement:
   ```bash
   codesign -s - --entitlements entitlements.plist -f .build/debug/MacWiimote
   ```

3. Run the executable:
   ```bash
   .build/debug/MacWiimote
   ```

4. Verify input functionality and rumble using [gamepad-tester.com](https://gamepad-tester.com) in any WebHID-compatible browser.
