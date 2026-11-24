// Streams the current Wi-Fi link's RSSI on macOS, one line per sample:
//   <rssi dBm> <noise dBm> <tx rate Mbps>
// Usage: swift rssi_mac.swift [interval_seconds]
// Read by wifi_motion_probe.py; not part of the Snappet app.
import CoreWLAN
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)
let interval = Double(CommandLine.arguments.dropFirst().first ?? "0.1") ?? 0.1

guard let iface = CWWiFiClient.shared().interface() else {
    FileHandle.standardError.write("no Wi-Fi interface found\n".data(using: .utf8)!)
    exit(1)
}

while true {
    print(iface.rssiValue(), iface.noiseMeasurement(), iface.transmitRate())
    Thread.sleep(forTimeInterval: interval)
}
