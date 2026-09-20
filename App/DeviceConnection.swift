import Combine
import CoreBluetooth
import PointCore

/// Foreground BLE setup. Legacy echo verification and negotiated navigation support
/// are separate: an echo must never be mistaken for working sensors or a motor.
@MainActor final class DeviceConnection: NSObject, ObservableObject {
    enum Phase { case idle, starting, scanning, connecting, discovering, verifying, connected, unavailable, failed }
    struct Device: Identifiable {
        let id: UUID
        let name: String
        let signal: Int?
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var devices: [Device] = []
    @Published private(set) var deviceName: String?
    @Published private(set) var message: String?
    @Published private(set) var lastReply: String?
    @Published private(set) var verifiedAt: Date?
    @Published private(set) var permissionDenied = false
    @Published private(set) var firmwareMessage = "Glove firmware support pending"
    @Published private(set) var canTestMotor = false
    @Published private(set) var canGuideIndoors = false
    @Published private(set) var indoorGuidanceMessage = "Connect your glove for pointing and vibration."
    @Published private(set) var sensorSummary: String?
    @Published private(set) var calibrationStatus = "Connect your glove to begin."
    @Published private(set) var calibrationLevels = "Waiting for sensor readings"
    @Published private(set) var capturingPose = false
    @Published private(set) var hasFirstPose = false
    @Published private(set) var pointingReady = false
    @Published private(set) var orientationSupported = false
    @Published private(set) var sensorReady = false
    let glove = FirmwareGlove()
    var keepsDemoRunningInBackground = false
    var onDemoReading: (() -> Void)?
    private let mountingStore = PointingCalibrationStore()
    private var firstPose: PointingCalibration.Pose?
    private var observations: [GloveOrientationSample] = []
    private var captureTask: Task<Void, Never>?
    private var setupOpen = false
    private var firmwareLoop: Task<Void, Never>?

    private var central: CBCentralManager?
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var peripheral: CBPeripheral?
    private var commandCharacteristic: CBCharacteristic?
    private var statusCharacteristic: CBCharacteristic?
    private var retiring: Set<UUID> = []
    private var probe: BTEchoProbe?
    private var timeout: Task<Void, Never>?
    private var wantsScan = false

    override init() {
        super.init()
        glove.write = { [weak self] data in
            guard let self, self.isConnected, let peripheral = self.peripheral,
                  let command = self.commandCharacteristic else { throw GloveTransportError.notConnected }
            peripheral.writeValue(data, for: command, type: .withResponse)
        }
        glove.onChange = { [weak self] in
            guard let self else { return }
            self.updateCalibration()
            let value = self.glove.message ?? "Glove firmware support pending"
            if self.firmwareMessage != value { self.firmwareMessage = value }
            let ready = self.glove.connection == .ready && self.glove.capabilities?.vibration == true
            if self.canTestMotor != ready { self.canTestMotor = ready }
            let indoorReady = ready && self.glove.magneticPointing() != nil
            if self.canGuideIndoors != indoorReady { self.canGuideIndoors = indoorReady }
            let indoorMessage: String
            if self.glove.connection != .ready { indoorMessage = "Connect your glove for pointing and vibration." }
            else if !ready { indoorMessage = "Glove motor unavailable. Check Device setup." }
            else if self.glove.pointingCalibration == nil { indoorMessage = "Set up the glove’s pointing direction before starting guidance." }
            else if let reason = self.glove.sensorHealth?.fusionBlockingReason { indoorMessage = reason }
            else if !indoorReady { indoorMessage = "Raise your hand and point forward to align the glove with the room." }
            else { indoorMessage = "Glove ready for room guidance." }
            if self.indoorGuidanceMessage != indoorMessage { self.indoorGuidanceMessage = indoorMessage }
            let sensor = self.glove.sensorHealth.map {
                $0.source == .bno055 ? "BNO055 · Primary compass" : "MPU6050 · Backup motion sensor"
            }
            if self.sensorSummary != sensor { self.sensorSummary = sensor }
        }
    }


    func beginSetup() {
        setupOpen = true
        updateCalibration()
    }

    private func updateCalibration() {
        let wasReady = sensorReady
        let setupBlock = glove.pointingSetupBlockingReason()
        let usable = setupBlock == nil
        if usable, glove.pointingCalibration == nil, !capturingPose, firstPose == nil,
           let id = peripheral?.identifier, let saved = mountingStore.load(for: id) {
            // calibrate publishes a change; the nested update sees a non-nil mapping.
            glove.calibrate(saved)
            calibrationStatus = "Saved glove direction restored. Repeat setup only if the sensor moves on the glove."
        }
        if sensorReady != usable { sensorReady = usable }
        if orientationSupported != glove.supportsOrientation { orientationSupported = glove.supportsOrientation }
        let ready = glove.pointingCalibration != nil
        if pointingReady != ready { pointingReady = ready }
        if let health = glove.sensorHealth {
            let levels = "System \(health.system)/3 · Gyro \(health.gyro)/3 · Accel \(health.accelerometer)/3 (optional) · Compass \(health.magnetometer)/3"
            if calibrationLevels != levels { calibrationLevels = levels }
        }
        if !usable {
            firstPose = nil
            if hasFirstPose { hasFirstPose = false }
            if capturingPose { cancelCapture() }
            let status = setupBlock ?? "Connect your glove to begin."
            if calibrationStatus != status { calibrationStatus = status }
            return
        }
        if !wasReady, !pointingReady, firstPose == nil {
            calibrationStatus = "Glove ready. Point your finger straight down and capture the first pose."
        }
        guard capturingPose, let sample = glove.orientation,
              observations.last?.timestamp != sample.timestamp else { return }
        observations.append(sample)
        if observations.count > 30 { observations.removeFirst() }
    }

    func capturePose() {
        guard setupOpen, !capturingPose, glove.pointingSetupBlockingReason() == nil else { return }
        if firstPose == nil {
            if let id = peripheral?.identifier { mountingStore.remove(for: id) }
            glove.resetPointingCalibration()
        }
        observations = []
        capturingPose = true
        calibrationStatus = "Hold your glove still for two seconds…"
        captureTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2.5)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            capturingPose = false
            guard let pose = PointingCalibration.capture(observations, direction: firstPose == nil ? .down : .up, now: Date()) else {
                calibrationStatus = "Couldn’t get a steady glove reading. Keep your finger straight in the requested pose and hold the glove still, then retry."
                return
            }
            if let firstPose {
                guard let calibration = PointingCalibration(first: firstPose, second: pose) else {
                    calibrationStatus = "The poses didn’t agree. Point the same straight finger directly upward and hold still. Keep the sensor fixed on your glove. Retry, or start over."
                    return
                }
                glove.calibrate(calibration)
                if let id = peripheral?.identifier { mountingStore.save(calibration, for: id) }
                self.firstPose = nil; hasFirstPose = false
                calibrationStatus = String(format: "Glove direction saved for next time. Raise your hand and point forward. Pose difference: %.1f°. Repeat setup only if the sensor moves.", calibration.validationError)
            } else {
                firstPose = pose; hasFirstPose = true
                calibrationStatus = "Downward pose saved. Now point the same straight finger directly upward and hold still."
            }
        }
    }

    func resetCalibration() {
        cancelCapture()
        firstPose = nil; hasFirstPose = false
        if let id = peripheral?.identifier { mountingStore.remove(for: id) }
        glove.resetPointingCalibration()
        calibrationStatus = "Point your finger straight down and hold still for the first pose."
    }

    private func cancelCapture() {
        captureTask?.cancel(); captureTask = nil
        capturingPose = false; observations = []
    }

    func testMotor() {
        do {
            try glove.testMotor()
            message = "Motor test requested. A device reply confirms receipt, not physical vibration."
        } catch GloveTransportError.busy {
            message = "The glove is finishing a stop request. Try the motor test again in a moment."
        } catch { message = "The glove is not ready for a motor test. Reconnect and check its firmware." }
    }

    var isConnected: Bool { phase == .connected }
    var isWorking: Bool { [.starting, .scanning, .connecting, .discovering, .verifying].contains(phase) }
    var hasLink: Bool { peripheral != nil }
    var canScan: Bool { !isWorking && !hasLink }
    var title: String {
        switch phase {
        case .idle: return devices.isEmpty ? "Connect your device" : "Choose your device"
        case .starting: return "Starting Bluetooth"
        case .scanning: return "Looking for your device"
        case .connecting: return "Connecting"
        case .discovering: return "Setting up the connection"
        case .verifying: return "Testing the connection"
        case .connected: return "Connection verified"
        case .unavailable: return "Bluetooth unavailable"
        case .failed: return "Connection needs attention"
        }
    }

    /// Creates the central manager at launch so the Bluetooth prompt appears with the other
    /// onboarding permissions. Nothing is scanned until the user asks.
    func prepare() {
        #if !targetEnvironment(simulator)
        guard central == nil else { return }
        central = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionShowPowerAlertKey: false])
        #endif
    }

    func scan() {
        guard canScan else { return }
        devices = []
        peripherals = [:]
        message = nil
        permissionDenied = false
        lastReply = nil
        verifiedAt = nil
        deviceName = nil
        wantsScan = true
        phase = .starting
        after(seconds: 15) { $0.fail("Bluetooth did not become available. Check Settings and try again.") }
        #if targetEnvironment(simulator)
        timeout?.cancel()
        wantsScan = false
        phase = .unavailable
        message = "Use Point on an iPhone to connect to the ESP32. The simulator can preview setup, but cannot test this Bluetooth link."
        #else
        if central == nil { prepare() }
        else if let central { centralManagerDidUpdateState(central) }
        #endif
    }

    private func beginScan() {
        guard let central, central.state == .poweredOn, wantsScan else { return }
        wantsScan = false
        phase = .scanning
        central.scanForPeripherals(withServices: [CBUUID(string: BTTestProtocol.serviceUUID)], options: nil)
        after(seconds: 12) { connection in
            connection.central?.stopScan()
            connection.phase = .idle
            if connection.devices.isEmpty {
                connection.message = "No device found. Power on your Point device with Bluetooth firmware, keep it nearby, and disconnect it from other Bluetooth apps before scanning again. The serial-only circuit test will not appear."
            }
        }
    }

    func connect(to device: Device) {
        guard [.idle, .scanning].contains(phase), let central, central.state == .poweredOn,
              let candidate = peripherals[device.id], !retiring.contains(device.id) else { return }
        timeout?.cancel()
        central.stopScan()
        wantsScan = false
        message = nil
        deviceName = device.name
        peripheral = candidate
        candidate.delegate = self
        phase = .connecting
        central.connect(candidate, options: nil)
        after(seconds: 20) { $0.fail("The device did not finish connecting. Move it closer and try again.") }
    }

    func testConnection() {
        guard phase == .connected || phase == .discovering,
              let peripheral, let commandCharacteristic,
              statusCharacteristic?.isNotifying == true else { return }
        firmwareLoop?.cancel()
        firmwareLoop = nil
        glove.disconnect()
        do { probe = try BTEchoProbe() }
        catch { fail("Could not prepare the connection test."); return }
        guard let probe else { return }
        phase = .verifying
        verifiedAt = nil
        lastReply = nil
        message = nil
        peripheral.writeValue(probe.command, for: commandCharacteristic, type: .withResponse)
        after(seconds: 5) { $0.fail("The device did not confirm the test message. Reconnect and check that the BT Test firmware is running.") }
    }

    func disconnect() {
        resetLink()
        phase = .idle
        message = nil
    }

    func setupDismissed() {
        setupOpen = false
        cancelCapture()
        firstPose = nil; hasFirstPose = false
        // Keep an established link, but never scan or connect invisibly behind the sheet.
        if isWorking { disconnect() }
    }

    func enteredBackground() {
        if keepsDemoRunningInBackground, isConnected {
            cancelCapture()
            central?.stopScan()
            wantsScan = false
            return
        }
        // Foreground-only prototype: do not leave a suspended connection owning the
        // firmware's single BLE slot or claim a link remains verified after suspension.
        let wasActive = isWorking || hasLink
        resetLink()
        if wasActive {
            phase = .idle
            message = "Connection closed while Point was in the background. Scan to reconnect."
        }
    }

    private func after(seconds: Double, action: @escaping @MainActor (DeviceConnection) -> Void) {
        timeout?.cancel()
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            action(self)
        }
    }

    private func resetLink() {
        cancelCapture()
        firstPose = nil; hasFirstPose = false
        firmwareLoop?.cancel()
        firmwareLoop = nil
        glove.disconnect()
        timeout?.cancel()
        timeout = nil
        wantsScan = false
        if central?.state == .poweredOn { central?.stopScan() }
        if let peripheral {
            peripheral.delegate = nil
            if central?.state == .poweredOn {
                retiring.insert(peripheral.identifier)
                central?.cancelPeripheralConnection(peripheral)
            }
        }
        peripheral = nil
        commandCharacteristic = nil
        statusCharacteristic = nil
        probe = nil
        verifiedAt = nil
        lastReply = nil
        deviceName = nil
        devices = []
        peripherals = [:]
    }

    private func fail(_ text: String) {
        resetLink()
        message = text
        phase = .failed
    }

    private func finishProbeIfReady() {
        guard phase == .verifying, probe?.isVerified == true else { return }
        timeout?.cancel()
        timeout = nil
        probe = nil
        verifiedAt = Date()
        phase = .connected
        glove.beginLink()
        firmwareLoop = Task { [weak self] in
            while !Task.isCancelled {
                self?.glove.tick()
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
        }
    }
}

extension DeviceConnection: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        permissionDenied = central.state == .unauthorized
        switch central.state {
        case .poweredOn:
            if wantsScan { beginScan() }
            else if phase == .unavailable { phase = .idle; message = nil }
        case .unknown, .resetting:
            retiring.removeAll()
            if peripheral != nil || phase == .scanning {
                resetLink()
                phase = .unavailable
                message = "Bluetooth is restarting. Scan again in a moment."
            }
        case .poweredOff, .unauthorized, .unsupported:
            resetLink()
            retiring.removeAll()
            phase = .unavailable
            switch central.state {
            case .poweredOff: message = "Turn on Bluetooth in Settings, then scan again."
            case .unauthorized: message = "Allow Point to use Bluetooth in Settings to find your device."
            default: message = "Bluetooth Low Energy is not available on this device. Use a supported iPhone."
            }
        @unknown default:
            resetLink()
            phase = .unavailable
            message = "Bluetooth is unavailable. Try again in a moment."
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard phase == .scanning, !retiring.contains(peripheral.identifier) else { return }
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? "Point device"
        peripherals[peripheral.identifier] = peripheral
        let device = Device(id: peripheral.identifier, name: name, signal: RSSI.intValue == 127 ? nil : RSSI.intValue)
        if let index = devices.firstIndex(where: { $0.id == device.id }) { devices[index] = device }
        else { devices.append(device) }
        devices.sort { ($0.signal ?? -200) > ($1.signal ?? -200) }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard self.peripheral === peripheral, phase == .connecting else {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        phase = .discovering
        peripheral.discoverServices([CBUUID(string: BTTestProtocol.serviceUUID)])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        retiring.remove(peripheral.identifier)
        guard self.peripheral === peripheral else { return }
        self.peripheral = nil
        fail("Could not connect. Check device power and close any other app connected to the board.")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        retiring.remove(peripheral.identifier)
        guard self.peripheral === peripheral else { return }
        self.peripheral = nil
        fail("The device disconnected. Keep it powered on and nearby, then scan to reconnect.")
    }
}

extension DeviceConnection: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard self.peripheral === peripheral, phase == .discovering else { return }
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == CBUUID(string: BTTestProtocol.serviceUUID) }) else {
            fail("The device does not expose the expected BT Test service. Check its firmware.")
            return
        }
        peripheral.discoverCharacteristics([CBUUID(string: BTTestProtocol.commandUUID), CBUUID(string: BTTestProtocol.statusUUID)], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard self.peripheral === peripheral, phase == .discovering else { return }
        guard error == nil,
              let command = service.characteristics?.first(where: { $0.uuid == CBUUID(string: BTTestProtocol.commandUUID) }),
              let status = service.characteristics?.first(where: { $0.uuid == CBUUID(string: BTTestProtocol.statusUUID) }),
              command.properties.contains(.write), status.properties.contains(.notify), status.properties.contains(.read) else {
            fail("This firmware is missing the command or status connection needed by Point.")
            return
        }
        commandCharacteristic = command
        statusCharacteristic = status
        peripheral.setNotifyValue(true, for: status)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard self.peripheral === peripheral, characteristic === statusCharacteristic else { return }
        guard error == nil, characteristic.isNotifying else {
            fail("Could not receive device replies. Reconnect and try again.")
            return
        }
        if phase == .discovering { testConnection() }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard self.peripheral === peripheral, characteristic === commandCharacteristic else { return }
        if phase == .connected {
            if error != nil { glove.writeFailed() }
            return
        }
        guard phase == .verifying else { return }
        guard error == nil else { fail("The device rejected the test message. Check the firmware and reconnect."); return }
        probe?.acknowledgeWrite()
        finishProbeIfReady()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard self.peripheral === peripheral, characteristic === statusCharacteristic else { return }
        guard error == nil, let data = characteristic.value else { fail("Could not read the device reply. Reconnect and try again."); return }
        if phase == .connected {
            glove.receive(data)
            if keepsDemoRunningInBackground {
                onDemoReading?()
                glove.tick()
            }
            return
        }
        lastReply = String(data: data, encoding: .utf8) ?? "Received \(data.count) bytes"
        guard phase == .verifying else { return }
        probe?.receive(data)
        finishProbeIfReady()
    }

    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        guard self.peripheral === peripheral,
              invalidatedServices.contains(where: { $0.uuid == CBUUID(string: BTTestProtocol.serviceUUID) }) else { return }
        fail("The device's Bluetooth service changed. Reconnect to set it up again.")
    }
}
