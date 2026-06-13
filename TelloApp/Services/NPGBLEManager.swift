// NPGBLEManager.swift
// BLE Central — listens for commands from "NPG Lite" ESP32
// and forwards them to TelloSDK.
//
// Flight commands:
//   "t"      → takeoff
//   "l"      → land
//   "b"      → flip right
//   "fd"     → forward  300ms pulse
//   "bd"     → backward 300ms pulse
//   "R"      → rotate CW 300ms pulse
//   "u"      → up 300ms pulse
//   "d"      → down 300ms pulse
//
// Mode commands (no flight action, UI update only):
//   "mode:V" → Vertical mode
//   "mode:R" → Rotation mode
//   "mode:H" → HOLD mode ON
//   "mode:F" → HOLD mode OFF (Fly resumed)

import Foundation
import CoreBluetooth

private let NPG_SERVICE_UUID = CBUUID(string: "4FAFC201-1FB5-459E-8FCC-C5C9C3319144")
private let NPG_CMD_UUID     = CBUUID(string: "BEB5483E-36E1-4688-B7F5-EA07361B26A8")

// MARK: - Mode enum
enum NPGMode {
    case vertical
    case rotation
    case hold

    var displayText: String {
        switch self {
        case .vertical:  return "⬆️  Vertical"
        case .rotation:  return "🔄  Rotation"
        case .hold:      return "✋  HOLD"
        }
    }
    var color: UIColor {
        switch self {
        case .vertical:  return UIColor(red: 0.2,  green: 0.85, blue: 0.4,  alpha: 1)
        case .rotation:  return UIColor(red: 1.0,  green: 0.75, blue: 0.0,  alpha: 1)
        case .hold:      return UIColor(red: 1.0,  green: 0.3,  blue: 0.3,  alpha: 1)
        }
    }
}

// MARK: - Delegate
protocol NPGBLEDelegate: AnyObject {
    func npgDidConnect(deviceName: String)
    func npgDidDisconnect()
    func npgDidReceiveCommand(_ cmd: String)
    func npgModeChanged(_ mode: NPGMode)
    func npgStatusChanged(_ status: String)
}

// Default empty implementations so conformers only implement what they need
extension NPGBLEDelegate {
    func npgModeChanged(_ mode: NPGMode) {}
}

// MARK: - Manager
final class NPGBLEManager: NSObject {

    static let shared = NPGBLEManager()
    private override init() {}

    weak var delegate: NPGBLEDelegate?

    // FIX: Set to true only when controlMode == .npg.
    // FlightViewController must toggle this via updateControlModeUI().
    // Starts false so manual mode (the default) never lets NPG commands through.
    var isCommandsEnabled: Bool = false

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var cmdCharacteristic: CBCharacteristic?
    private(set) var isConnected = false
    private(set) var currentMode: NPGMode = .vertical

    private var pulseTimer: DispatchSourceTimer?
    private var bleRetryCount = 0
    private let bleMaxRetries = 20  // ~40 sec total retry window

    // MARK: - Public
    func startScanning() {
        central = CBCentralManager(delegate: self, queue: DispatchQueue.global(qos: .userInitiated))
    }

    func stopScanning() {
        guard central?.state == .poweredOn else { return }
        central.stopScan()
    }

    func disconnect() {
        stopPulse()
        if let p = peripheral { central?.cancelPeripheralConnection(p) }
    }

    // MARK: - Command Execution
    func executeCommand(_ raw: String) {
        let cmd = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else { return }

        // Mode commands always update state + notify delegate regardless of mode,
        // but only send Tello actions (HOLD stop) when commands are enabled.
        if cmd.hasPrefix("mode:") {
            let modeStr = String(cmd.dropFirst(5))
            let newMode: NPGMode
            switch modeStr {
            case "R": newMode = .rotation
            case "H": newMode = .hold
            case "F", "V": newMode = .vertical
            default: return
            }
            currentMode = newMode

            // HOLD ON → send "stop" so Tello hovers stably (SDK 2.0 stop cmd)
            // HOLD OFF → RC will resume naturally on next EMG/blink command
            if newMode == .hold && isCommandsEnabled {
                stopPulse()
                TelloSDK.shared.stopRC()
                TelloSDK.shared.resetRC()
                // Small delay then send stop so Tello position-holds
//                DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
//                    TelloSDK.shared.sendCommand("stop")
//                }
            }
            // Note: on HOLD OFF ("mode:F") we don't need to do anything —
            // next EMG cmd from ESP32 will resume RC naturally.

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.npgModeChanged(newMode)
                self.delegate?.npgDidReceiveCommand(cmd)
            }
            return
        }

        // FIX: Gate all flight commands — if NPG mode is not active, notify UI and stop here.
        guard isCommandsEnabled else {
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.npgDidReceiveCommand("__ignored__")
            }
            return
        }

        // Flight commands
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.npgDidReceiveCommand(cmd)
        }

        switch cmd {
        case "t":
            TelloSDK.shared.takeoff()

        case "l":
            TelloSDK.shared.land()

        case "b":
            TelloSDK.shared.stopRC()
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) {
                TelloSDK.shared.sendCommand("cw 360")
            }

        case "fd": sendRCPulse(lr: 0, fb:  100, ud:   0, yaw:   0)
        case "bd": sendRCPulse(lr: 0, fb: -100, ud:   0, yaw:   0)
        case "R":  sendRCPulse(lr: 0, fb:    0, ud:   0, yaw: 100)
        case "u":  sendRCPulse(lr: 0, fb:    0, ud: 50, yaw:   0)
        case "d":  sendRCPulse(lr: 0, fb:    0, ud: -50, yaw:  0)

        default:
            print("[NPG BLE] Unknown cmd: '\(cmd)'")
        }
    }

    // MARK: - RC Pulse
    private func sendRCPulse(lr: Int, fb: Int, ud: Int, yaw: Int) {
        stopPulse()
        TelloSDK.shared.rcLR  = lr
        TelloSDK.shared.rcFB  = fb
        TelloSDK.shared.rcUD  = ud
        TelloSDK.shared.rcYaw = yaw
        TelloSDK.shared.sendCommand("rc \(lr) \(fb) \(ud) \(yaw)")

        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
        t.schedule(deadline: .now() + 0.30)
        t.setEventHandler { [weak self] in
            TelloSDK.shared.rcLR  = 0; TelloSDK.shared.rcFB  = 0
            TelloSDK.shared.rcUD  = 0; TelloSDK.shared.rcYaw = 0
            TelloSDK.shared.sendCommand("rc 0 0 0 0")
            self?.pulseTimer = nil
        }
        t.resume()
        pulseTimer = t
    }

    private func stopPulse() { pulseTimer?.cancel(); pulseTimer = nil }
}

// MARK: - CBCentralManagerDelegate
extension NPGBLEManager: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            DispatchQueue.main.async { self.delegate?.npgStatusChanged("🔍 Scanning for NPG Lite…") }
            central.scanForPeripherals(withServices: [NPG_SERVICE_UUID], options: nil)
        case .poweredOff:
            DispatchQueue.main.async { self.delegate?.npgStatusChanged("📵 Bluetooth off") }
        case .unauthorized:
            DispatchQueue.main.async { self.delegate?.npgStatusChanged("⚠️ BLE unauthorized") }
        default:
            DispatchQueue.main.async { self.delegate?.npgStatusChanged("⚙️ BLE initializing…") }
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? "NPG Lite"
        self.peripheral = peripheral
        central.stopScan()
        central.connect(peripheral, options: nil)
        DispatchQueue.main.async { self.delegate?.npgStatusChanged("⏳ Connecting to \(name)…") }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        self.peripheral = peripheral
        peripheral.delegate = self
        peripheral.discoverServices([NPG_SERVICE_UUID])
        isConnected = true
        bleRetryCount = 0  // reset on successful connect
        let name = peripheral.name ?? "NPG Lite"
        DispatchQueue.main.async {
            self.delegate?.npgDidConnect(deviceName: name)
            self.delegate?.npgStatusChanged("✅ \(name) connected")
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        isConnected = false; self.peripheral = nil; cmdCharacteristic = nil
        bleRetryCount += 1
        DispatchQueue.main.async {
            self.delegate?.npgDidDisconnect()
        }
        guard bleRetryCount <= bleMaxRetries else {
            DispatchQueue.main.async {
                self.delegate?.npgStatusChanged("❌ NPG not found — open app again")
            }
            return
        }
        DispatchQueue.main.async {
            self.delegate?.npgStatusChanged("🔴 NPG disconnected — rescanning (\(self.bleRetryCount)/\(self.bleMaxRetries))…")
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
            if self.central?.state == .poweredOn {
                self.central.scanForPeripherals(withServices: [NPG_SERVICE_UUID], options: nil)
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        isConnected = false
        bleRetryCount += 1
        guard bleRetryCount <= bleMaxRetries else {
            DispatchQueue.main.async {
                self.delegate?.npgStatusChanged("❌ NPG not found — open app again")
            }
            return
        }
        DispatchQueue.main.async { self.delegate?.npgStatusChanged("❌ NPG connect failed — retrying (\(self.bleRetryCount)/\(self.bleMaxRetries))…") }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
            if self.central?.state == .poweredOn {
                self.central.scanForPeripherals(withServices: [NPG_SERVICE_UUID], options: nil)
            }
        }
    }
}

// MARK: - CBPeripheralDelegate
extension NPGBLEManager: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else { return }
        for service in peripheral.services ?? [] {
            if service.uuid == NPG_SERVICE_UUID {
                peripheral.discoverCharacteristics([NPG_CMD_UUID], for: service)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil else { return }
        for char in service.characteristics ?? [] {
            if char.uuid == NPG_CMD_UUID {
                cmdCharacteristic = char
                if char.properties.contains(.notify) {
                    peripheral.setNotifyValue(true, for: char)
                }
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, characteristic.uuid == NPG_CMD_UUID,
              let data = characteristic.value,
              let text = String(data: data, encoding: .utf8) else { return }
        print("[NPG BLE] Received: '\(text)'")
        executeCommand(text)
    }
}

// Needed for NPGMode.color to reference UIColor
import UIKit
