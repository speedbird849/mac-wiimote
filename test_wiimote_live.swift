import Foundation
import IOKit
import IOKit.hid

print("==================================================")
print("     Connecting to Paired Nintendo Wii Remote     ")
print("==================================================")

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

let matching: [String: Any] = [
    kIOHIDVendorIDKey as String: 0x057E,
    kIOHIDProductIDKey as String: 0x0306
]
IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

let openStatus = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
guard openStatus == kIOReturnSuccess else {
    print("[-] Failed to open IOHIDManager: \(openStatus)")
    exit(1)
}

print("[+] IOHIDManager opened successfully.")

func sendOutputReport(device: IOHIDDevice, data: [UInt8]) {
    var payload = data
    let reportID = CFIndex(payload[0])
    let res = payload.withUnsafeMutableBytes { ptr -> IOReturn in
        IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, reportID, ptr.baseAddress!, ptr.count)
    }
    if res != kIOReturnSuccess {
        print("[-] IOHIDDeviceSetReport failed: \(String(format: "0x%08X", res))")
    }
}

var targetDevice: IOHIDDevice?

let inputCallback: IOHIDReportCallback = { context, result, sender, type, reportID, report, reportLength in
    guard reportLength > 0 else { return }
    let data = Data(bytes: report, count: reportLength)
    let id = data[0]
    
    if id == 0x35 && data.count >= 22 {
        // Mode 0x35:
        // Byte 0: 0x35
        // Bytes 1-2: Buttons
        // Bytes 3-5: Accelerometer (10-bit)
        // Bytes 6-21: Extension / MotionPlus (16 bytes)
        let btnRaw = UInt16(data[1]) | (UInt16(data[2]) << 8)
        let aPressed = (btnRaw & 0x0008) != 0
        let bPressed = (btnRaw & 0x0004) != 0
        let onePressed = (btnRaw & 0x0002) != 0
        let twoPressed = (btnRaw & 0x0001) != 0
        let plusPressed = (btnRaw & 0x1000) != 0
        let minusPressed = (btnRaw & 0x0010) != 0
        let homePressed = (btnRaw & 0x0080) != 0
        
        let accelX = Int(data[3])
        let accelY = Int(data[4])
        let accelZ = Int(data[5])
        
        // MotionPlus 6-byte data in bytes 6..11
        // Yaw, Roll, Pitch (14-bit)
        let yawLow = Int(data[6])
        let rollLow = Int(data[7])
        let pitchLow = Int(data[8])
        let yawHigh = (Int(data[9]) >> 2) & 0x3F
        let rollHigh = (Int(data[10]) >> 2) & 0x3F
        let pitchHigh = (Int(data[11]) >> 2) & 0x3F
        
        let yawSlow = (data[9] & 0x02) != 0
        let rollSlow = (data[10] & 0x02) != 0
        let pitchSlow = (data[11] & 0x02) != 0
        let mpAttached = (data[10] & 0x01) != 0
        
        let yaw = (yawHigh << 8) | yawLow
        let roll = (rollHigh << 8) | rollLow
        let pitch = (pitchHigh << 8) | pitchLow
        
        var pressedNames = [String]()
        if aPressed { pressedNames.append("A") }
        if bPressed { pressedNames.append("B") }
        if onePressed { pressedNames.append("1") }
        if twoPressed { pressedNames.append("2") }
        if plusPressed { pressedNames.append("+") }
        if minusPressed { pressedNames.append("-") }
        if homePressed { pressedNames.append("Home") }
        let btnStr = pressedNames.isEmpty ? "[None]" : pressedNames.joined(separator: ", ")
        
        print("🎮 Buttons: \(btnStr.padding(toLength: 15, withPad: " ", startingAt: 0)) | Accel: X=\(accelX) Y=\(accelY) Z=\(accelZ) | Gyro: Pitch=\(pitch) Roll=\(roll) Yaw=\(yaw) (MP: \(mpAttached ? "Active" : "Init"))")
    } else if id == 0x30 || id == 0x31 {
        let btnRaw = UInt16(data[1]) | (UInt16(data[2]) << 8)
        print("📦 Report 0x\(String(format: "%02X", id)): Buttons raw: 0x\(String(format: "%04X", btnRaw))")
    } else if id == 0x20 {
        print("🔋 Status Report 0x20 received! Battery raw: \(data.count > 6 ? data[6] : 0)")
    } else if id == 0x21 {
        print("📝 Memory Read Acknowledged (Report 0x21)")
    } else if id == 0x22 {
        print("✅ Acknowledge / Write Report 0x22 received")
    } else {
        print("ℹ️ Incoming Report: 0x\(String(format: "%02X", id)) (Length: \(data.count))")
    }
}

let matchCallback: IOHIDDeviceCallback = { context, result, sender, device in
    print("\n[+] MATCHED WIIMOTE IOHIDDevice: \(device)")
    targetDevice = device
    
    let bufferSize = 64
    let reportBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    IOHIDDeviceRegisterInputReportCallback(device, reportBuffer, bufferSize, inputCallback, nil)
    
    // 1. Quick rumble buzz + turn on Player LED 1
    print("[*] Buzzing rumble motor & lighting LED 1...")
    sendOutputReport(device: device, data: [0x11, 0x11]) // LED 1 + Rumble ON
    
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
        sendOutputReport(device: device, data: [0x11, 0x10]) // LED 1 + Rumble OFF
        print("[+] Rumble buzz test complete. LED 1 is solid.")
        
        // 2. Request status
        print("[*] Requesting Wiimote status...")
        sendOutputReport(device: device, data: [0x15, 0x00])
        
        // 3. Initialize MotionPlus (Address space 0x04A600F0 <- 0x55)
        print("[*] Sending MotionPlus Init Step 1 (0x55 -> 0x04A600F0)...")
        var init1 = [UInt8](repeating: 0, count: 22)
        init1[0] = 0x16 // Write register
        init1[1] = 0x04 // Address space (0x04 = Extension)
        init1[2] = 0xA6 // High addr
        init1[3] = 0x00 // Mid addr
        init1[4] = 0xF0 // Low addr
        init1[5] = 0x01 // Data length = 1
        init1[6] = 0x55 // Value
        sendOutputReport(device: device, data: init1)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            print("[*] Sending MotionPlus Init Step 2 (0x04 -> 0x04A600FE)...")
            var init2 = [UInt8](repeating: 0, count: 22)
            init2[0] = 0x16
            init2[1] = 0x04
            init2[2] = 0xA6
            init2[3] = 0x00
            init2[4] = 0xFE
            init2[5] = 0x01
            init2[6] = 0x04 // Activate MotionPlus
            sendOutputReport(device: device, data: init2)
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                print("[*] Setting Report Mode 0x35 (Buttons + Accelerometer + MotionPlus)...")
                sendOutputReport(device: device, data: [0x12, 0x00, 0x35])
                print("[+] Wiimote configured! Streaming live sensor data now...")
                print("[*] Try pressing buttons or moving your Wiimote!")
            }
        }
    }
}

IOHIDManagerRegisterDeviceMatchingCallback(manager, matchCallback, nil)

// In case it's already attached right now, manually iterate:
if let deviceSet = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> {
    for dev in deviceSet {
        matchCallback(nil, kIOReturnSuccess, nil, dev)
    }
}

print("[*] Listening for Wiimote input stream (Ctrl+C to stop)...")
RunLoop.current.run(until: Date().addingTimeInterval(15))
print("\nSession complete!")
