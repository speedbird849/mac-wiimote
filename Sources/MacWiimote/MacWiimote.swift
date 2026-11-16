import Foundation
import CoreHID
import IOKit
import IOKit.hid

// Global references
nonisolated(unsafe) private var physicalWiimoteDevice: IOHIDDevice?
nonisolated(unsafe) private var currentLEDMask: UInt8 = 0x10 // LED 1
nonisolated(unsafe) private var virtualDevice: HIDVirtualDevice?

// Gyro & Accelerometer calibration
nonisolated(unsafe) private var isCalibrated = false
nonisolated(unsafe) private var calibrationSamples = 0
nonisolated(unsafe) private var biasPitch: Double = 8192.0
nonisolated(unsafe) private var biasRoll: Double = 8192.0
nonisolated(unsafe) private var biasYaw: Double = 8192.0

// Accelerometer resting calibration (face-up on table)
nonisolated(unsafe) private var biasAccelX: Double = 512.0
nonisolated(unsafe) private var biasAccelY: Double = 512.0
nonisolated(unsafe) private var restingAccelZ: Double = 616.0
nonisolated(unsafe) private var scale1G: Double = 104.0

nonisolated(unsafe) private var packetCount = 0

func sendWiimoteReport(data: [UInt8]) {
    guard let dev = physicalWiimoteDevice else { return }
    var payload = data
    let reportID = CFIndex(payload[0])
    _ = payload.withUnsafeMutableBytes { ptr in
        IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, reportID, ptr.baseAddress!, ptr.count)
    }
}

func setPhysicalWiimoteRumble(on: Bool) {
    sendWiimoteReport(data: [0x11, on ? (currentLEDMask | 0x01) : currentLEDMask])
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

// Global C-compatible callbacks
func wiimoteInputCallback(context: UnsafeMutableRawPointer?, result: IOReturn, sender: UnsafeMutableRawPointer?, type: IOHIDReportType, reportID: UInt32, report: UnsafeMutablePointer<UInt8>, reportLength: CFIndex) {
    guard reportLength > 0 else { return }
    let data = Data(bytes: report, count: reportLength)
    let id = data[0]
    
    packetCount += 1
    
    if id == 0x35 && data.count >= 22 {
        let b1 = data[1]
        let b2 = data[2]
        
        // Parse Digital Buttons
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
        }
        
        // Accelerometer 10-bit reconstruction (0..1023, center ~512)
        let rawX10 = (Int(data[3]) << 2) | ((Int(b1) >> 5) & 0x03)
        let rawY10 = (Int(data[4]) << 2) | ((Int(b2) >> 4) & 0x02)
        let rawZ10 = (Int(data[5]) << 2) | ((Int(b2) >> 5) & 0x02)
        
        // MotionPlus Gyro (14-bit angular rates)
        let yawLow = Int(data[6])
        let rollLow = Int(data[7])
        let pitchLow = Int(data[8])
        let yawHigh = (Int(data[9]) >> 2) & 0x3F
        let rollHigh = (Int(data[10]) >> 2) & 0x3F
        let pitchHigh = (Int(data[11]) >> 2) & 0x3F
        
        let rawYaw = Double((yawHigh << 8) | yawLow)
        let rawRoll = Double((rollHigh << 8) | rollLow)
        let rawPitch = Double((pitchHigh << 8) | pitchLow)
        
        // Calibration for first 60 frames while resting flat, buttons up
        if !isCalibrated {
            calibrationSamples += 1
            if calibrationSamples == 1 {
                biasPitch = rawPitch
                biasRoll  = rawRoll
                biasYaw   = rawYaw
                biasAccelX = Double(rawX10)
                biasAccelY = Double(rawY10)
                restingAccelZ = Double(rawZ10)
            } else {
                biasPitch += (rawPitch - biasPitch) * 0.08
                biasRoll  += (rawRoll  - biasRoll)  * 0.08
                biasYaw   += (rawYaw   - biasYaw)   * 0.08
                biasAccelX += (Double(rawX10) - biasAccelX) * 0.08
                biasAccelY += (Double(rawY10) - biasAccelY) * 0.08
                restingAccelZ += (Double(rawZ10) - restingAccelZ) * 0.08
            }
            
            if calibrationSamples >= 60 {
                isCalibrated = true
                // 1G is difference between resting Z (+1G) and ~512 (0G)
                scale1G = max(restingAccelZ - 512.0, 80.0)
                print(String(format: "[+] Calibration complete! Resting pose locked."))
                print(String(format: "    Accel zero bias: X=%.1f, Y=%.1f | Resting Z (+1G): %.1f | Scale1G: %.1f counts/G", biasAccelX, biasAccelY, restingAccelZ, scale1G))
                print(String(format: "    Gyro zero bias: Pitch=%.1f, Roll=%.1f, Yaw=%.1f", biasPitch, biasRoll, biasYaw))
                print("[*] Tip: You can press the 'Home' button anytime while resting flat to re-zero!")
            }
        }
        
        // Scaled Accelerometer (-32768 to 32767, resting on desk = 0 on all axes, +/- 1G = full deflection)
        let diffX = Double(rawX10) - biasAccelX
        let diffY = Double(rawY10) - biasAccelY
        let diffZ = Double(rawZ10) - restingAccelZ
        let accelX = Int16(clamping: Int((diffX / scale1G) * 32767.0))
        let accelY = Int16(clamping: Int((diffY / scale1G) * 32767.0))
        let accelZ = Int16(clamping: Int((diffZ / scale1G) * 32767.0))
        
        // Scaled Gyroscope (angular velocities)
        let gyroPitch = Int16(clamping: Int((rawPitch - biasPitch) * 24.0))
        let gyroRoll  = Int16(clamping: Int((rawRoll  - biasRoll)  * 24.0))
        let gyroYaw   = Int16(clamping: Int((rawYaw   - biasYaw)   * 24.0))
        
        // Assemble Virtual USB Gamepad report (Report ID 1, 15 bytes total)
        var virtualReport = Data([0x01])
        withUnsafeBytes(of: buttons.littleEndian) { virtualReport.append(contentsOf: $0) }
        withUnsafeBytes(of: accelX.littleEndian) { virtualReport.append(contentsOf: $0) }
        withUnsafeBytes(of: accelY.littleEndian) { virtualReport.append(contentsOf: $0) }
        withUnsafeBytes(of: accelZ.littleEndian) { virtualReport.append(contentsOf: $0) }
        withUnsafeBytes(of: gyroPitch.littleEndian) { virtualReport.append(contentsOf: $0) }
        withUnsafeBytes(of: gyroRoll.littleEndian) { virtualReport.append(contentsOf: $0) }
        withUnsafeBytes(of: gyroYaw.littleEndian) { virtualReport.append(contentsOf: $0) }
        
        if let dev = virtualDevice {
            Task {
                try? await dev.dispatchInputReport(data: virtualReport, timestamp: .now)
            }
        }
        
        if packetCount % 50 == 0 || buttons != 0 {
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
            let btnStr = pressed.isEmpty ? "[None]" : pressed.joined(separator: "+")
            print(String(format: "🎮 Telemetry | Buttons: %@ | Accel: X=%6d Y=%6d Z=%6d | Gyro: P=%6d R=%6d Y=%6d",
                         btnStr.padding(toLength: 10, withPad: " ", startingAt: 0),
                         accelX, accelY, accelZ, gyroPitch, gyroRoll, gyroYaw))
        }
    }
}

func startWiimoteInitialization(device: IOHIDDevice) {
    Task {
        // Immediately set Player 1 LED to SOLID (0x10) and ensure rumble is strictly OFF (0x00)
        print("[*] Setting Player 1 LED and silencing rumble...")
        sendWiimoteReport(data: [0x11, 0x10])
        
        try? await Task.sleep(nanoseconds: 100_000_000)
        
        // Wake up MotionPlus Extension
        print("[*] Initializing MotionPlus extension (Step 1)...")
        var init1 = [UInt8](repeating: 0, count: 22)
        init1[0] = 0x16; init1[1] = 0x04; init1[2] = 0xA6; init1[3] = 0x00; init1[4] = 0xF0; init1[5] = 0x01; init1[6] = 0x55
        sendWiimoteReport(data: init1)
        
        try? await Task.sleep(nanoseconds: 100_000_000)
        
        print("[*] Initializing MotionPlus extension (Step 2)...")
        var init2 = [UInt8](repeating: 0, count: 22)
        init2[0] = 0x16; init2[1] = 0x04; init2[2] = 0xA6; init2[3] = 0x00; init2[4] = 0xFE; init2[5] = 0x01; init2[6] = 0x04
        sendWiimoteReport(data: init2)
        
        try? await Task.sleep(nanoseconds: 100_000_000)
        
        print("[*] Requesting Continuous Report Mode 0x35 (Buttons + Accelerometer + MotionPlus)...")
        sendWiimoteReport(data: [0x12, 0x00, 0x35])
        
        print("")
        print("🎮 ==================================================")
        print("   PHYSICAL WIIMOTE IS LIVE AS A USB GAMEPAD!         ")
        print("   1. Open https://gamepad-tester.com                ")
        print("   2. Move the Wiimote, tilt it, press buttons!       ")
        print("   3. Test Rumble on gamepad-tester.com to feel motor!")
        print("====================================================")
    }
}

func wiimoteMatchCallback(context: UnsafeMutableRawPointer?, result: IOReturn, sender: UnsafeMutableRawPointer?, device: IOHIDDevice) {
    let transport = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String
    if transport == "Virtual" {
        return // Ignore our own virtual device!
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
        
        // --- Accelerometer: X, Y, Z (3 x 16-bit signed) ---
        0x05, 0x01,        //   Usage Page (Generic Desktop Ctrls)
        0x09, 0x30,        //   Usage (X)
        0x09, 0x31,        //   Usage (Y)
        0x09, 0x32,        //   Usage (Z)
        0x16, 0x00, 0x80,  //   Logical Minimum (-32768)
        0x26, 0xFF, 0x7F,  //   Logical Maximum (32767)
        0x75, 0x10,        //   Report Size (16 bits)
        0x95, 0x03,        //   Report Count (3)
        0x81, 0x02,        //   Input (Data,Var,Abs)
        
        // --- Gyroscope: Rx, Ry, Rz (3 x 16-bit signed) ---
        0x09, 0x33,        //   Usage (Rx - Pitch rate)
        0x09, 0x34,        //   Usage (Ry - Roll rate)
        0x09, 0x35,        //   Usage (Rz - Yaw rate)
        0x16, 0x00, 0x80,  //   Logical Minimum (-32768)
        0x26, 0xFF, 0x7F,  //   Logical Maximum (32767)
        0x75, 0x10,        //   Report Size (16 bits)
        0x95, 0x03,        //   Report Count (3)
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
