import Foundation
import CoreHID
import IOKit
import IOKit.hid

// Global references
nonisolated(unsafe) private var physicalWiimoteDevice: IOHIDDevice?
nonisolated(unsafe) private var currentLEDMask: UInt8 = 0x10 // LED 1
nonisolated(unsafe) private var virtualDevice: HIDVirtualDevice?

// =========================================================================
// FIXED CALIBRATION CONSTANTS (DETERMINISTIC ACROSS ALL CONNECTIONS)
// No dynamic re-calibration on connect: connecting at ANY angle yields
// the exact same calibrated midpoints and scale every time.
// =========================================================================

// Wiimote ADXL330 Accelerometer (10-bit: 0..1023)
// Midpoint X & Y are 0G center (~500.0). Midpoint Z is resting flat buttons-up (+1G ~615.0).
// Sensitivity is ~104.0 counts per 1G.
private let fixedAccelMidpointX: Double = 500.0
private let fixedAccelMidpointY: Double = 500.0
private let fixedAccelMidpointZ: Double = 615.0
private let fixedScale1G: Double = 104.0

// MotionPlus Gyroscope (Nominal zero rate ~8192; cached as 0 when not active)
private let fixedGyroBiasPitch: Double = 7890.0
private let fixedGyroBiasRoll: Double = 8400.0
private let fixedGyroBiasYaw: Double = 8145.0

// Nunchuk Joystick & Accelerometer
// Stick center is ~128.0 (deadzone ±6). Accel 0G center is ~512.0, resting Z (+1G) is ~720.0, scale is ~210.0.
private let fixedNunchukCenterX: Double = 128.0
private let fixedNunchukCenterY: Double = 128.0
private let fixedNunchukAccelMidpointX: Double = 512.0
private let fixedNunchukAccelMidpointY: Double = 512.0
private let fixedNunchukAccelMidpointZ: Double = 720.0
private let fixedNunchukScale1G: Double = 210.0

// Cached Gyroscope Values
nonisolated(unsafe) private var cachedGyroPitch: Int16 = 0
nonisolated(unsafe) private var cachedGyroRoll: Int16 = 0
nonisolated(unsafe) private var cachedGyroYaw: Int16 = 0

// Nunchuk Hotplug & State
nonisolated(unsafe) private var isNunchukConnected = false
nonisolated(unsafe) private var isHandlingExtChange = false

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
    let ret = payload.withUnsafeMutableBytes { ptr in
        IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, reportID, ptr.baseAddress!, ptr.count)
    }
    if ret != kIOReturnSuccess {
        print("[-] sendWiimoteReport(0x\(String(format: "%02X", payload[0]))) failed: 0x\(String(format: "%08X", UInt32(bitPattern: ret)))")
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

// Hotplug Handler for Nunchuk Extension via Hardware Report 0x20
func handleExtensionStateChange(connected: Bool) {
    guard connected != isNunchukConnected else { return }
    isNunchukConnected = connected
    
    if !connected {
        // Disconnected: immediately zero out cached Nunchuk inputs
        cachedNunchukStickX = 0
        cachedNunchukStickY = 0
        cachedNunchukAccelX = 0
        cachedNunchukAccelY = 0
        cachedNunchukAccelZ = 0
        cachedNunchukBtnC = false
        cachedNunchukBtnZ = false
        
        print("")
        print("🔌 ==================================================")
        print("   NUNCHUK UNPLUGGED! Reverting to Wiimote Standalone")
        print("====================================================")
        sendWiimoteReport(data: [0x12, 0x04, 0x31])
        return
    }
    
    guard !isHandlingExtChange else { return }
    isHandlingExtChange = true
    
    Task {
        print("")
        print("🔌 ==================================================")
        print("   NUNCHUK DETECTED! Initializing extension...      ")
        print("====================================================")
        
        // Step 1: Disable encryption ("The New Way")
        writeWiimoteRegister(address: 0xA400F0, value: 0x55)
        try? await Task.sleep(nanoseconds: 50_000_000)
        
        // Step 2: Complete initialization
        writeWiimoteRegister(address: 0xA400FB, value: 0x00)
        try? await Task.sleep(nanoseconds: 50_000_000)
        
        // Step 3: Request Continuous Reporting Mode 0x35 (Buttons + Accel + Extension)
        sendWiimoteReport(data: [0x12, 0x04, 0x35])
        print("[+] Nunchuk initialized successfully (Mode 0x35 active).")
        
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
    
    // -----------------------------------------------------------------
    // Status Report 0x20: Authoritative Hardware Notification
    // Automatically sent by Wiimote whenever an extension is plugged or unplugged
    // -----------------------------------------------------------------
    if id == 0x20 && data.count >= 4 {
        let hasExtension = (data[3] & 0x02) != 0
        handleExtensionStateChange(connected: hasExtension)
        // Wiibrew specification: Unsolicited 0x20 requires 0x12 to re-affirm continuous mode
        sendWiimoteReport(data: [0x12, 0x04, hasExtension ? 0x35 : 0x31])
        return
    }
    
    // Process Data Reporting Modes: 0x31 (Buttons + Accel) or 0x35 (Buttons + Accel + Extension)
    guard (id == 0x31 && data.count >= 6) || (id == 0x35 && data.count >= 12) else {
        return
    }
    
    packetCount += 1
    
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
    
    // Accelerometer 10-bit reconstruction (0..1023)
    let rawX10 = (Int(data[3]) << 2) | ((Int(b1) >> 5) & 0x03)
    let rawY10 = (Int(data[4]) << 2) | ((Int(b2) >> 4) & 0x02)
    let rawZ10 = (Int(data[5]) << 2) | ((Int(b2) >> 5) & 0x02)
    
    // Scaled Wiimote Accelerometer using FIXED deterministic midpoints
    let diffX = Double(rawX10) - fixedAccelMidpointX
    let diffY = Double(rawY10) - fixedAccelMidpointY
    let diffZ = Double(rawZ10) - fixedAccelMidpointZ
    let accelX = Int16(clamping: Int((diffX / fixedScale1G) * 32767.0))
    let accelY = Int16(clamping: Int((diffY / fixedScale1G) * 32767.0))
    let accelZ = Int16(clamping: Int((diffZ / fixedScale1G) * 32767.0))
    
    // Process Nunchuk Extension Payload if connected and reporting in Mode 0x35
    if isNunchukConnected && id == 0x35 && data.count >= 12 {
        // Sanity-check: ignore open-bus noise (0xFF floating lines)
        let isOpenBus = (data[6] == 0xFF && data[7] == 0xFF && data[8] == 0xFF && data[9] == 0xFF)
        if !isOpenBus {
            let rawSX = Double(data[6])
            let rawSY = Double(data[7])
            let b5 = data[11]
            
            // Nunchuk Buttons: Active Low (0 = pressed, 1 = released)
            // Bit 1 = Button C, Bit 0 = Button Z
            cachedNunchukBtnC = (b5 & 0x02) == 0
            cachedNunchukBtnZ = (b5 & 0x01) == 0
            
            // Scaled Nunchuk Stick: -32768 to 32767 (with ±6 deadzone)
            var diffSX = rawSX - fixedNunchukCenterX
            var diffSY = rawSY - fixedNunchukCenterY
            if abs(diffSX) < 6.0 { diffSX = 0.0 }
            if abs(diffSY) < 6.0 { diffSY = 0.0 }
            cachedNunchukStickX = Int16(clamping: Int((diffSX / 80.0) * 32767.0))
            cachedNunchukStickY = Int16(clamping: Int((-diffSY / 80.0) * 32767.0))
            
            // Scaled Nunchuk Accelerometer: 10-bit reconstruction
            // Upper 8 bits in data[8..10], lower 2 bits in b5
            // AX<1:0> in bits 3..2, AY<1:0> in bits 5..4, AZ<1:0> in bits 7..6
            let rawNx10 = (Int(data[8]) << 2) | Int((b5 >> 2) & 0x03)
            let rawNy10 = (Int(data[9]) << 2) | Int((b5 >> 4) & 0x03)
            let rawNz10 = (Int(data[10]) << 2) | Int((b5 >> 6) & 0x03)
            
            let diffNx = Double(rawNx10) - fixedNunchukAccelMidpointX
            let diffNy = Double(rawNy10) - fixedNunchukAccelMidpointY
            let diffNz = Double(rawNz10) - fixedNunchukAccelMidpointZ
            cachedNunchukAccelX = Int16(clamping: Int((diffNx / fixedNunchukScale1G) * 32767.0))
            cachedNunchukAccelY = Int16(clamping: Int((diffNy / fixedNunchukScale1G) * 32767.0))
            cachedNunchukAccelZ = Int16(clamping: Int((diffNz / fixedNunchukScale1G) * 32767.0))
        }
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
            print(String(format: "🎮 Telemetry [NUNCHUK] | Btns: %@ | Stick: X=%6d Y=%6d | Wiimote Accel: X=%6d Y=%6d | Nunchuk Accel: X=%6d Y=%6d Z=%6d",
                         btnStr.padding(toLength: 12, withPad: " ", startingAt: 0),
                         cachedNunchukStickX, cachedNunchukStickY,
                         accelX, accelY,
                         cachedNunchukAccelX, cachedNunchukAccelY, cachedNunchukAccelZ))
        } else {
            print(String(format: "🎮 Telemetry [WIIMOTE] | Btns: %@ | Accel: X=%6d Y=%6d Z=%6d",
                         btnStr.padding(toLength: 12, withPad: " ", startingAt: 0),
                         accelX, accelY, accelZ))
        }
    }
}

func startWiimoteInitialization(device: IOHIDDevice) {
    Task {
        // 1. Immediately set Player 1 LED to SOLID (0x10) and ensure rumble is strictly OFF (0x00)
        print("[*] Setting Player 1 LED and silencing rumble...")
        sendWiimoteReport(data: [0x11, 0x10])
        try? await Task.sleep(nanoseconds: 100_000_000)
        
        // 2. Query Status (Report 0x15) to detect if an extension is already attached
        print("[*] Querying Wiimote hardware status (Report 0x15)...")
        sendWiimoteReport(data: [0x15, 0x00])
        try? await Task.sleep(nanoseconds: 150_000_000)
        
        // 3. Fallback: If no extension was detected from status query, start standalone mode 0x31
        if !isNunchukConnected {
            print("[*] No extension detected at startup. Starting Standalone Mode 0x31...")
            sendWiimoteReport(data: [0x12, 0x04, 0x31])
        }
        
        print("")
        print("🎮 ==================================================")
        print("   PHYSICAL WIIMOTE IS LIVE AS A USB GAMEPAD!        ")
        print("   - Calibration: FIXED DETERMINISTIC MIDPOINTS ACTIVE")
        print("   - Wiimote Tilt: Accel X/Y/Z (Fixed midpoints)     ")
        print("   - Nunchuk: Dynamic hardware hotplug active (0x20) ")
        print("   - 1. Open https://gamepad-tester.com              ")
        print("   - 2. Connect / disconnect Nunchuk to test!        ")
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
        print("[+] Fixed Deterministic Midpoints Loaded:")
        print("    - Wiimote Accel: Midpoint (X=\(fixedAccelMidpointX), Y=\(fixedAccelMidpointY), Z=\(fixedAccelMidpointZ)) | Scale: \(fixedScale1G)")
        print("    - Nunchuk Stick: Center (X=\(fixedNunchukCenterX), Y=\(fixedNunchukCenterY))")
        print("    - Nunchuk Accel: Midpoint (X=\(fixedNunchukAccelMidpointX), Y=\(fixedNunchukAccelMidpointY), Z=\(fixedNunchukAccelMidpointZ)) | Scale: \(fixedNunchukScale1G)")
        print("[*] Connection at ANY angle will use these exact midpoints.")
        print("[*] Extension Hotplug: Listening for hardware Report 0x20")
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
