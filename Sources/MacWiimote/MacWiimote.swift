import Foundation
import CoreHID
import IOKit
import IOKit.hid

// Global references
nonisolated(unsafe) private var physicalWiimoteDevice: IOHIDDevice?
nonisolated(unsafe) private var currentLEDMask: UInt8 = 0x10 // LED 1
nonisolated(unsafe) private var virtualDevice: HIDVirtualDevice?

// Wiimote Calibration & State
nonisolated(unsafe) private var isCalibrated = false
nonisolated(unsafe) private var calibrationSamples = 0
nonisolated(unsafe) private var biasPitch: Double = 8192.0
nonisolated(unsafe) private var biasRoll: Double = 8192.0
nonisolated(unsafe) private var biasYaw: Double = 8192.0

nonisolated(unsafe) private var biasAccelX: Double = 512.0
nonisolated(unsafe) private var biasAccelY: Double = 512.0
nonisolated(unsafe) private var restingAccelZ: Double = 616.0
nonisolated(unsafe) private var scale1G: Double = 104.0

// Cached Gyroscope Values (MotionPlus)
nonisolated(unsafe) private var cachedGyroPitch: Int16 = 0
nonisolated(unsafe) private var cachedGyroRoll: Int16 = 0
nonisolated(unsafe) private var cachedGyroYaw: Int16 = 0

// Nunchuk Hotplug & Calibration State
nonisolated(unsafe) private var isNunchukConnected = false
nonisolated(unsafe) private var isHandlingExtChange = false
nonisolated(unsafe) private var nunchukCalibrated = false
nonisolated(unsafe) private var nunchukCalibrationSamples = 0

nonisolated(unsafe) private var nunchukCenterX: Double = 128.0
nonisolated(unsafe) private var nunchukCenterY: Double = 128.0
nonisolated(unsafe) private var nunchukAccelBiasX: Double = 512.0
nonisolated(unsafe) private var nunchukAccelBiasY: Double = 512.0
nonisolated(unsafe) private var nunchukAccelRestZ: Double = 740.0
nonisolated(unsafe) private var nunchukScale1G: Double = 220.0

nonisolated(unsafe) private var cachedNunchukStickX: Int16 = 0
nonisolated(unsafe) private var cachedNunchukStickY: Int16 = 0
nonisolated(unsafe) private var cachedNunchukAccelX: Int16 = 0
nonisolated(unsafe) private var cachedNunchukAccelY: Int16 = 0
nonisolated(unsafe) private var cachedNunchukAccelZ: Int16 = 0
nonisolated(unsafe) private var cachedNunchukBtnC = false
nonisolated(unsafe) private var cachedNunchukBtnZ = false

nonisolated(unsafe) private var packetCount = 0

// Communication Helpers
func sendWiimoteReport(data: [UInt8]) {
    guard let dev = physicalWiimoteDevice else { return }
    var payload = data
    let reportID = CFIndex(payload[0])
    _ = payload.withUnsafeMutableBytes { ptr in
        IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, reportID, ptr.baseAddress!, ptr.count)
    }
}

func writeWiimoteRegister(address: UInt32, value: UInt8) {
    var report = [UInt8](repeating: 0, count: 22)
    report[0] = 0x16 // Write register report
    report[1] = 0x04 // Control register address space
    report[2] = UInt8((address >> 16) & 0xFF)
    report[3] = UInt8((address >> 8) & 0xFF)
    report[4] = UInt8(address & 0xFF)
    report[5] = 0x01 // 1 byte
    report[6] = value
    sendWiimoteReport(data: report)
}

func setPhysicalWiimoteRumble(on: Bool) {
    sendWiimoteReport(data: [0x11, on ? (currentLEDMask | 0x01) : currentLEDMask])
}

// Hotplug Handler for Nunchuk Extension
func handleExtensionStateChange(connected: Bool) {
    guard connected != isNunchukConnected else { return }
    guard !isHandlingExtChange else { return }
    isHandlingExtChange = true
    isNunchukConnected = connected
    
    Task {
        if connected {
            print("")
            print("🔌 ==================================================")
            print("   NUNCHUK DETECTED! Activating Pass-Through Mode... ")
            print("====================================================")
            
            // Wake MotionPlus and set pass-through mode
            writeWiimoteRegister(address: 0x04A600F0, value: 0x55)
            try? await Task.sleep(nanoseconds: 60_000_000)
            writeWiimoteRegister(address: 0x04A600FE, value: 0x05)
            writeWiimoteRegister(address: 0x04A400FE, value: 0x05)
            try? await Task.sleep(nanoseconds: 60_000_000)
            
            // Reset Nunchuk calibration
            nunchukCalibrated = false
            nunchukCalibrationSamples = 0
            
            // Request continuous reporting mode 0x35
            sendWiimoteReport(data: [0x12, 0x00, 0x35])
            print("[+] Nunchuk pass-through activated successfully!")
        } else {
            print("")
            print("🔌 ==================================================")
            print("   NUNCHUK UNPLUGGED! Restoring MotionPlus Standalone")
            print("====================================================")
            
            // Reset cached Nunchuk inputs to neutral
            cachedNunchukStickX = 0
            cachedNunchukStickY = 0
            cachedNunchukAccelX = 0
            cachedNunchukAccelY = 0
            cachedNunchukAccelZ = 0
            cachedNunchukBtnC = false
            cachedNunchukBtnZ = false
            
            // Restore MotionPlus standalone mode
            writeWiimoteRegister(address: 0x04A600F0, value: 0x55)
            try? await Task.sleep(nanoseconds: 60_000_000)
            writeWiimoteRegister(address: 0x04A600FE, value: 0x04)
            writeWiimoteRegister(address: 0x04A400FE, value: 0x04)
            try? await Task.sleep(nanoseconds: 60_000_000)
            
            // Request continuous reporting mode 0x35
            sendWiimoteReport(data: [0x12, 0x00, 0x35])
            print("[+] Standalone MotionPlus restored.")
        }
        
        isHandlingExtChange = false
    }
}

final class VirtualGamepadDelegate: HIDVirtualDeviceDelegate, @unchecked Sendable {
    func hidVirtualDevice(_ device: HIDVirtualDevice, receivedSetReportRequestOfType type: HIDReportType, id: HIDReportID?, data: Data) async throws {
        let rumbleValue: UInt8 = {
            if data.count >= 2 && data[0] == 1 {
                return data[1]
            }
            return data.first ?? 0
        }()
        setPhysicalWiimoteRumble(on: rumbleValue > 0)
    }
    
    func hidVirtualDevice(_ device: HIDVirtualDevice, receivedGetReportRequestOfType type: HIDReportType, id: HIDReportID?, maxSize: Int) async throws -> Data {
        return Data()
    }
}

// Global C-compatible Wiimote input callback
func wiimoteInputCallback(context: UnsafeMutableRawPointer?, result: IOReturn, sender: UnsafeMutableRawPointer?, type: IOHIDReportType, reportID: UInt32, report: UnsafeMutablePointer<UInt8>, reportLength: CFIndex) {
    guard reportLength > 0 else { return }
    let data = Data(bytes: report, count: reportLength)
    let id = data[0]
    
    // Status Report 0x20: Sent automatically when extensions are plugged/unplugged
    if id == 0x20 && data.count >= 4 {
        let extConnected = (data[3] & 0x02) != 0
        handleExtensionStateChange(connected: extConnected)
        return
    }
    
    packetCount += 1
    
    if id == 0x35 && data.count >= 22 {
        let b1 = data[1]
        let b2 = data[2]
        
        // Parse Digital Buttons (Core Wiimote)
        var buttons: UInt16 = 0
        if (b2 & 0x08) != 0 { buttons |= (1 << 0) } // Btn 1: A
        if (b2 & 0x04) != 0 { buttons |= (1 << 1) } // Btn 2: B
        if (b2 & 0x02) != 0 { buttons |= (1 << 2) } // Btn 3: 1
        if (b2 & 0x01) != 0 { buttons |= (1 << 3) } // Btn 4: 2
        if (b2 & 0x10) != 0 { buttons |= (1 << 4) } // Btn 5: Minus
        if (b1 & 0x10) != 0 { buttons |= (1 << 5) } // Btn 6: Plus
        if (b2 & 0x80) != 0 { buttons |= (1 << 6) } // Btn 7: Home
        if (b1 & 0x08) != 0 { buttons |= (1 << 7) } // Btn 8: D-Pad Up
        if (b1 & 0x04) != 0 { buttons |= (1 << 8) } // Btn 9: D-Pad Down
        if (b1 & 0x01) != 0 { buttons |= (1 << 9) } // Btn 10: D-Pad Left
        if (b1 & 0x02) != 0 { buttons |= (1 << 10) }// Btn 11: D-Pad Right
        
        // Re-calibrate zero pose if Home button is pressed while already calibrated
        if (b2 & 0x80) != 0 && isCalibrated {
            print("[*] Home button pressed -> Re-calibrating zero pose (keep Wiimote still on desk)...")
            isCalibrated = false
            calibrationSamples = 0
            nunchukCalibrated = false
            nunchukCalibrationSamples = 0
        }
        
        // Accelerometer 10-bit reconstruction (0..1023, center ~512)
        let rawX10 = (Int(data[3]) << 2) | ((Int(b1) >> 5) & 0x03)
        let rawY10 = (Int(data[4]) << 2) | ((Int(b2) >> 4) & 0x02)
        let rawZ10 = (Int(data[5]) << 2) | ((Int(b2) >> 5) & 0x02)
        
        // Wiimote Calibration for first 60 frames while resting flat, buttons up
        if !isCalibrated {
            calibrationSamples += 1
            if calibrationSamples == 1 {
                biasAccelX = Double(rawX10)
                biasAccelY = Double(rawY10)
                restingAccelZ = Double(rawZ10)
            } else {
                biasAccelX += (Double(rawX10) - biasAccelX) * 0.08
                biasAccelY += (Double(rawY10) - biasAccelY) * 0.08
                restingAccelZ += (Double(rawZ10) - restingAccelZ) * 0.08
            }
            
            if calibrationSamples >= 60 {
                isCalibrated = true
                scale1G = max(restingAccelZ - 512.0, 80.0)
                print(String(format: "[+] Calibration complete! Resting pose locked."))
                print(String(format: "    Wiimote Accel bias: X=%.1f, Y=%.1f | Rest Z (+1G): %.1f | Scale1G: %.1f counts/G", biasAccelX, biasAccelY, restingAccelZ, scale1G))
                print(String(format: "    Wiimote Gyro bias: Pitch=%.1f, Roll=%.1f, Yaw=%.1f", biasPitch, biasRoll, biasYaw))
                print("[*] Tip: You can press the 'Home' button anytime while resting flat to re-zero!")
            }
        }
        
        // Scaled Wiimote Accelerometer (-32768 to 32767)
        let diffX = Double(rawX10) - biasAccelX
        let diffY = Double(rawY10) - biasAccelY
        let diffZ = Double(rawZ10) - restingAccelZ
        let accelX = Int16(clamping: Int((diffX / scale1G) * 32767.0))
        let accelY = Int16(clamping: Int((diffY / scale1G) * 32767.0))
        let accelZ = Int16(clamping: Int((diffZ / scale1G) * 32767.0))
        
        // Process Extension Payload (Bytes 6..21)
        // Bit 1 of Byte 5 (data[11]) determines packet type in pass-through mode:
        // 1 = MotionPlus Gyro, 0 = Nunchuk Extension
        let isMPPacket = (data[11] & 0x02) != 0
        
        if isMPPacket {
            // MotionPlus Packet: 14-bit angular rates
            let yawLow = Int(data[6])
            let rollLow = Int(data[7])
            let pitchLow = Int(data[8])
            let yawHigh = (Int(data[9]) >> 2) & 0x3F
            let rollHigh = (Int(data[10]) >> 2) & 0x3F
            let pitchHigh = (Int(data[11]) >> 2) & 0x3F
            
            let rawYaw = Double((yawHigh << 8) | yawLow)
            let rawRoll = Double((rollHigh << 8) | rollLow)
            let rawPitch = Double((pitchHigh << 8) | pitchLow)
            
            if !isCalibrated {
                biasPitch += (rawPitch - biasPitch) * 0.08
                biasRoll  += (rawRoll  - biasRoll)  * 0.08
                biasYaw   += (rawYaw   - biasYaw)   * 0.08
            }
            
            cachedGyroPitch = Int16(clamping: Int((rawPitch - biasPitch) * 24.0))
            cachedGyroRoll  = Int16(clamping: Int((rawRoll  - biasRoll)  * 24.0))
            cachedGyroYaw   = Int16(clamping: Int((rawYaw   - biasYaw)   * 24.0))
            
            // Check hardware Extension Connected bit in Byte 4 Bit 0
            let extConnectedBit = (data[10] & 0x01) != 0
            if extConnectedBit != isNunchukConnected {
                handleExtensionStateChange(connected: extConnectedBit)
            }
        } else {
            // Nunchuk Pass-Through Packet
            if !isNunchukConnected {
                isNunchukConnected = true
            }
            
            let rawSX = Double(data[6])
            let rawSY = Double(data[7])
            
            let b5 = data[11]
            let rawNx10 = (Int(data[8]) << 2) | ((Int(b5) >> 3) & 0x02)
            let rawNy10 = (Int(data[9]) << 2) | ((Int(b5) >> 4) & 0x02)
            let rawNz10 = (Int(data[10]) << 2) | ((Int(b5) >> 5) & 0x02)
            
            // Nunchuk Buttons in pass-through mode:
            // Bit 3 = Button C, Bit 2 = Button Z (Active Low: 0 = pressed)
            cachedNunchukBtnC = (b5 & 0x08) == 0
            cachedNunchukBtnZ = (b5 & 0x04) == 0
            
            // Auto-center Nunchuk analog stick & zero accelerometer
            if !nunchukCalibrated {
                nunchukCalibrationSamples += 1
                if nunchukCalibrationSamples == 1 {
                    nunchukCenterX = rawSX
                    nunchukCenterY = rawSY
                    nunchukAccelBiasX = Double(rawNx10)
                    nunchukAccelBiasY = Double(rawNy10)
                    nunchukAccelRestZ = Double(rawNz10)
                } else {
                    nunchukCenterX += (rawSX - nunchukCenterX) * 0.1
                    nunchukCenterY += (rawSY - nunchukCenterY) * 0.1
                    nunchukAccelBiasX += (Double(rawNx10) - nunchukAccelBiasX) * 0.1
                    nunchukAccelBiasY += (Double(rawNy10) - nunchukAccelBiasY) * 0.1
                    nunchukAccelRestZ += (Double(rawNz10) - nunchukAccelRestZ) * 0.1
                }
                
                if nunchukCalibrationSamples >= 30 {
                    nunchukCalibrated = true
                    nunchukScale1G = max(nunchukAccelRestZ - 512.0, 100.0)
                    print(String(format: "[+] Nunchuk zero-calibration complete! Center: (%.1f, %.1f) | Rest Z: %.1f", nunchukCenterX, nunchukCenterY, nunchukAccelRestZ))
                }
            }
            
            // Scaled Nunchuk Stick: -32768 to 32767
            let diffSX = rawSX - nunchukCenterX
            let diffSY = rawSY - nunchukCenterY
            cachedNunchukStickX = Int16(clamping: Int((diffSX / 80.0) * 32767.0))
            cachedNunchukStickY = Int16(clamping: Int((-diffSY / 80.0) * 32767.0))
            
            // Scaled Nunchuk Accelerometer: -32768 to 32767
            let diffNx = Double(rawNx10) - nunchukAccelBiasX
            let diffNy = Double(rawNy10) - nunchukAccelBiasY
            let diffNz = Double(rawNz10) - nunchukAccelRestZ
            cachedNunchukAccelX = Int16(clamping: Int((diffNx / nunchukScale1G) * 32767.0))
            cachedNunchukAccelY = Int16(clamping: Int((diffNy / nunchukScale1G) * 32767.0))
            cachedNunchukAccelZ = Int16(clamping: Int((diffNz / nunchukScale1G) * 32767.0))
        }
        
        // Assemble Virtual USB Gamepad report
        var buttonsOut = buttons
        if cachedNunchukBtnC { buttonsOut |= (1 << 11) } // Button 12: Nunchuk C
        if cachedNunchukBtnZ { buttonsOut |= (1 << 12) } // Button 13: Nunchuk Z
        
        // Primary stick axes: Nunchuk joystick if connected, otherwise Wiimote tilt steering fallback
        let axis0 = isNunchukConnected ? cachedNunchukStickX : accelX
        let axis1 = isNunchukConnected ? cachedNunchukStickY : accelY
        
        var virtualReport = Data([0x01]) // Report ID 1
        withUnsafeBytes(of: buttonsOut.littleEndian) { virtualReport.append(contentsOf: $0) }
        withUnsafeBytes(of: axis0.littleEndian) { virtualReport.append(contentsOf: $0) }
        withUnsafeBytes(of: axis1.littleEndian) { virtualReport.append(contentsOf: $0) }
        withUnsafeBytes(of: accelX.littleEndian) { virtualReport.append(contentsOf: $0) }
        withUnsafeBytes(of: accelY.littleEndian) { virtualReport.append(contentsOf: $0) }
        withUnsafeBytes(of: accelZ.littleEndian) { virtualReport.append(contentsOf: $0) }
        withUnsafeBytes(of: cachedGyroPitch.littleEndian) { virtualReport.append(contentsOf: $0) }
        withUnsafeBytes(of: cachedGyroRoll.littleEndian) { virtualReport.append(contentsOf: $0) }
        withUnsafeBytes(of: cachedGyroYaw.littleEndian) { virtualReport.append(contentsOf: $0) }
        withUnsafeBytes(of: cachedNunchukAccelX.littleEndian) { virtualReport.append(contentsOf: $0) }
        withUnsafeBytes(of: cachedNunchukAccelY.littleEndian) { virtualReport.append(contentsOf: $0) }
        withUnsafeBytes(of: cachedNunchukAccelZ.littleEndian) { virtualReport.append(contentsOf: $0) }
        
        if let dev = virtualDevice {
            Task {
                try? await dev.dispatchInputReport(data: virtualReport, timestamp: .now)
            }
        }
        
        if packetCount % 50 == 0 || buttonsOut != 0 {
            var pressed = [String]()
            if (b2 & 0x08) != 0 { pressed.append("A") }
            if (b2 & 0x04) != 0 { pressed.append("B") }
            if (b2 & 0x02) != 0 { pressed.append("1") }
            if (b2 & 0x01) != 0 { pressed.append("2") }
            if (b2 & 0x10) != 0 { pressed.append("-") }
            if (b1 & 0x10) != 0 { pressed.append("+") }
            if (b2 & 0x80) != 0 { pressed.append("Home") }
            if (b1 & 0x08) != 0 { pressed.append("Up") }
            if (b1 & 0x04) != 0 { pressed.append("Down") }
            if (b1 & 0x01) != 0 { pressed.append("Left") }
            if (b1 & 0x02) != 0 { pressed.append("Right") }
            if cachedNunchukBtnC { pressed.append("C") }
            if cachedNunchukBtnZ { pressed.append("Z") }
            let btnStr = pressed.isEmpty ? "[None]" : pressed.joined(separator: "+")
            
            if isNunchukConnected {
                print(String(format: "🎮 Telemetry | Buttons: %@ | Nunchuk Stick: X=%6d Y=%6d | Wiimote Accel: X=%6d Y=%6d | Nunchuk Accel: X=%6d Y=%6d",
                             btnStr.padding(toLength: 12, withPad: " ", startingAt: 0),
                             cachedNunchukStickX, cachedNunchukStickY,
                             accelX, accelY,
                             cachedNunchukAccelX, cachedNunchukAccelY))
            } else {
                print(String(format: "🎮 Telemetry | Buttons: %@ | Wiimote Accel: X=%6d Y=%6d Z=%6d | Gyro: P=%6d R=%6d Y=%6d",
                             btnStr.padding(toLength: 12, withPad: " ", startingAt: 0),
                             accelX, accelY, accelZ, cachedGyroPitch, cachedGyroRoll, cachedGyroYaw))
            }
        }
    }
}

func startWiimoteInitialization(device: IOHIDDevice) {
    Task {
        // 1. Immediately set Player 1 LED to SOLID (0x10) and ensure rumble is strictly OFF (0x00)
        print("[*] Setting Player 1 LED and silencing rumble...")
        sendWiimoteReport(data: [0x11, 0x10])
        try? await Task.sleep(nanoseconds: 100_000_000)
        
        // 2. Query Wiimote status to detect attached extensions
        print("[*] Querying extension status...")
        sendWiimoteReport(data: [0x15, 0x00])
        try? await Task.sleep(nanoseconds: 150_000_000)
        
        // 3. Wake up MotionPlus Extension (Step 1: 0x55 -> 0xA600F0)
        print("[*] Initializing MotionPlus extension (Step 1: 0x55 -> 0xA600F0)...")
        writeWiimoteRegister(address: 0x04A600F0, value: 0x55)
        try? await Task.sleep(nanoseconds: 100_000_000)
        
        // 4. Activate MotionPlus mode based on whether extension is detected
        if isNunchukConnected {
            print("[*] Initializing MotionPlus in NUNCHUK PASS-THROUGH mode (Step 2: 0x05 -> 0xA600FE)...")
            writeWiimoteRegister(address: 0x04A600FE, value: 0x05)
            writeWiimoteRegister(address: 0x04A400FE, value: 0x05)
            try? await Task.sleep(nanoseconds: 100_000_000)
        } else {
            print("[*] Initializing MotionPlus in STANDALONE mode (Step 2: 0x04 -> 0xA600FE)...")
            writeWiimoteRegister(address: 0x04A600FE, value: 0x04)
            writeWiimoteRegister(address: 0x04A400FE, value: 0x04)
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        
        // 5. Request Continuous Report Mode 0x35 (Buttons + Accelerometer + Extension)
        print("[*] Requesting Continuous Report Mode 0x35 (Buttons + Accelerometer + Extension)...")
        sendWiimoteReport(data: [0x12, 0x00, 0x35])
        
        print("")
        print("🎮 ==================================================")
        print("   PHYSICAL WIIMOTE + NUNCHUK IS LIVE AS A USB GAMEPAD!")
        print("   - Wiimote Tilt: Accel X/Y/Z                       ")
        print("   - Wiimote Gyro: Pitch/Roll/Yaw (MotionPlus)       ")
        print("   - Nunchuk: Analog Stick, Buttons C & Z, Tilt Accel")
        print("   - Hotplug: Plug/unplug Nunchuk dynamically anytime")
        print("   - 1. Open https://gamepad-tester.com              ")
        print("   - 2. Move Nunchuk stick, press C & Z!             ")
        print("   - 3. Test Rumble on gamepad-tester.com!           ")
        print("====================================================")
    }
}

func wiimoteMatchCallback(context: UnsafeMutableRawPointer?, result: IOReturn, sender: UnsafeMutableRawPointer?, device: IOHIDDevice) {
    let transport = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String
    if transport == "Virtual" {
        return // Ignore our own virtual device!
    }
    if physicalWiimoteDevice != nil {
        return // Already linked!
    }
    
    print("[+] Linked to Physical Bluetooth Wii Remote: \(device)")
    physicalWiimoteDevice = device
    
    let bufferSize = 64
    let reportBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    IOHIDDeviceRegisterInputReportCallback(device, reportBuffer, bufferSize, wiimoteInputCallback, nil)
    
    startWiimoteInitialization(device: device)
}

func setupVirtualDevice() async {
    let descriptorBytes: [UInt8] = [
        0x05, 0x01,        // Usage Page (Generic Desktop Ctrls)
        0x09, 0x05,        // Usage (Game Pad)
        0xA1, 0x01,        // Collection (Application)
        0x85, 0x01,        //   Report ID (1)
        
        // --- 16 Buttons ---
        0x05, 0x09,        //   Usage Page (Button)
        0x19, 0x01,        //   Usage Minimum (Button 1)
        0x29, 0x10,        //   Usage Maximum (Button 16)
        0x15, 0x00,        //   Logical Minimum (0)
        0x25, 0x01,        //   Logical Maximum (1)
        0x75, 0x01,        //   Report Size (1 bit)
        0x95, 0x10,        //   Report Count (16 buttons = 2 bytes)
        0x81, 0x02,        //   Input (Data,Var,Abs)
        
        // --- 11 Analog Axes (16-bit signed) ---
        0x05, 0x01,        //   Usage Page (Generic Desktop Ctrls)
        0x09, 0x30,        //   Usage (X) - Axis 0: Primary Stick X (Nunchuk Stick X / Wiimote Tilt X)
        0x09, 0x31,        //   Usage (Y) - Axis 1: Primary Stick Y (Nunchuk Stick Y / Wiimote Tilt Y)
        0x09, 0x32,        //   Usage (Z) - Axis 2: Wiimote Accel X
        0x09, 0x33,        //   Usage (Rx) - Axis 3: Wiimote Accel Y
        0x09, 0x34,        //   Usage (Ry) - Axis 4: Wiimote Accel Z
        0x09, 0x35,        //   Usage (Rz) - Axis 5: Gyro Pitch
        0x09, 0x36,        //   Usage (Slider) - Axis 6: Gyro Roll
        0x09, 0x37,        //   Usage (Dial) - Axis 7: Gyro Yaw
        0x09, 0x40,        //   Usage (Vx) - Axis 8: Nunchuk Accel X
        0x09, 0x41,        //   Usage (Vy) - Axis 9: Nunchuk Accel Y
        0x09, 0x42,        //   Usage (Vz) - Axis 10: Nunchuk Accel Z
        0x16, 0x00, 0x80,  //   Logical Minimum (-32768)
        0x26, 0xFF, 0x7F,  //   Logical Maximum (32767)
        0x75, 0x10,        //   Report Size (16 bits)
        0x95, 0x0B,        //   Report Count (11 axes = 22 bytes)
        0x81, 0x02,        //   Input (Data,Var,Abs)
        
        // --- Output Report for Rumble (1 byte) ---
        0x85, 0x01,        //   Report ID (1)
        0x05, 0x01,        //   Usage Page (Generic Desktop)
        0x09, 0x00,        //   Usage (Undefined / Rumble)
        0x15, 0x00,        //   Logical Minimum (0)
        0x26, 0xFF, 0x00,  //   Logical Maximum (255)
        0x75, 0x08,        //   Report Size (8 bits)
        0x95, 0x01,        //   Report Count (1 byte)
        0x91, 0x02,        //   Output (Data,Var,Abs)
        
        0xC0               // End Collection
    ]
    
    let properties = HIDVirtualDevice.Properties(
        descriptor: Data(descriptorBytes),
        vendorID: 0x057E,
        productID: 0x0307,
        product: "Nintendo Wii Remote (USB Virtual)",
        manufacturer: "Nintendo"
    )
    
    guard let vDev = HIDVirtualDevice(properties: properties) else {
        print("[-] Failed to create CoreHID virtual device.")
        return
    }
    
    virtualDevice = vDev
    let vDelegate = VirtualGamepadDelegate()
    await vDev.activate(delegate: vDelegate)
    print("[+] Virtual USB Gamepad initialized in macOS kernel.")
}

@main
struct MacWiimote {
    static func main() {
        print("==================================================")
        print("     Nintendo Wii Remote -> Virtual USB Gamepad   ")
        print("==================================================")
        
        // 1. Setup Virtual Device asynchronously
        Task {
            await setupVirtualDevice()
        }
        
        // 2. Setup IOHIDManager with RunLoop
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDVendorIDKey as String: 0x057E,
            kIOHIDProductIDKey as String: 0x0306
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        
        let openStatus = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openStatus == kIOReturnSuccess else {
            if openStatus == kIOReturnExclusiveAccess {
                print("[-] Error: Exclusive access conflict (kIOReturnExclusiveAccess).")
                print("    Please completely quit Dolphin or wiimacmote (Cmd+Q) and try again.")
            } else {
                print("[-] Failed to open IOHIDManager: \(String(format: "0x%08X", UInt32(bitPattern: openStatus)))")
            }
            return
        }
        
        IOHIDManagerRegisterDeviceMatchingCallback(manager, wiimoteMatchCallback, nil)
        
        if let deviceSet = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> {
            for dev in deviceSet {
                wiimoteMatchCallback(context: nil, result: kIOReturnSuccess, sender: nil, device: dev)
            }
        }
        
        // Pump Main RunLoop to process HID input reports
        CFRunLoopRun()
    }
}
