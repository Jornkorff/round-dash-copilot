import Foundation
import CoreBluetooth

final class BLEBroadcaster: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let serviceUUID = CBUUID(string: "4FAFC201-1FB5-459E-8FCC-C5C9C331914B")
    static let charUUID    = CBUUID(string: "BEB5483E-36E1-4688-B7F5-EA07361B26A8")

    @Published var isConnected: Bool = false
    @Published var peripheralName: String = "Scanning..."
    @Published var packetsSent: Int = 0

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var frameChar: CBCharacteristic?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            startScanning()
        } else {
            isConnected = false
            peripheralName = "Bluetooth Powered Off"
        }
    }

    func startScanning() {
        peripheralName = "Scanning for RoundDash..."
        central.scanForPeripherals(
            withServices: [Self.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        self.peripheral = peripheral
        self.peripheralName = peripheral.name ?? "RoundDash-Copilot"
        peripheral.delegate = self
        central.stopScan()
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        isConnected = true
        self.peripheralName = peripheral.name ?? "RoundDash Connected"
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        isConnected = false
        self.frameChar = nil
        startScanning()
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let svc = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else { return }
        peripheral.discoverCharacteristics([Self.charUUID], for: svc)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        frameChar = service.characteristics?.first(where: { $0.uuid == Self.charUUID })
    }

    func sendFrame(_ data: Data) {
        guard let p = peripheral, let c = frameChar, p.state == .connected else { return }
        p.writeValue(data, for: c, type: .withoutResponse)
        DispatchQueue.main.async { [weak self] in
            self?.packetsSent += 1
        }
    }
}
