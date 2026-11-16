import Foundation
import IOBluetooth

if let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] {
    for d in devices {
        if d.nameOrAddress?.contains("Nintendo") == true || d.nameOrAddress?.contains("RVL") == true {
            print("Found paired Wiimote: \(d.addressString ?? "")")
            print("Is connected? \(d.isConnected())")
            if !d.isConnected() {
                print("Calling openConnection()...")
                let res = d.openConnection()
                print("openConnection result: \(res)")
            }
        }
    }
}
