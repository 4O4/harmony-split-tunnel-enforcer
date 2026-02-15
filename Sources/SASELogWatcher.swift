import Foundation

final class SASELogWatcher {
    static let logPath = "/var/log/HarmonySASE/HarmonySASEd.log"
    static let routeLogPath = "/var/log/HarmonySASE/routingTable.log"

    private var _isRunning = false
    private let lock = DispatchQueue(label: "com.harmony.saselogwatcher.lock")

    private var isRunning: Bool {
        get { lock.sync { _isRunning } }
        set { lock.sync { _isRunning = newValue } }
    }

    /// Called on main thread when SASE daemon reports VPN connected
    var onVPNConnected: (() -> Void)?

    /// Called on main thread when SASE daemon reports VPN disconnected
    var onVPNDisconnected: (() -> Void)?

    /// Whether the SASE daemon log file exists
    static var logFileExists: Bool {
        FileManager.default.fileExists(atPath: logPath)
    }

    /// Whether the SASE route log file exists
    static var routeLogFileExists: Bool {
        FileManager.default.fileExists(atPath: routeLogPath)
    }

    func start() {
        guard !isRunning else { return }
        guard Self.logFileExists else {
            SplitTunnelEngine.shared.log("[SASELogWatcher] Log file not found at \(Self.logPath), skipping")
            return
        }
        isRunning = true
        SplitTunnelEngine.shared.log("[SASELogWatcher] Starting log watcher")

        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.tailLoop()
        }
    }

    func stop() {
        isRunning = false
    }

    private func tailLoop() {
        while isRunning {
            guard FileManager.default.fileExists(atPath: Self.logPath) else {
                if isRunning { Thread.sleep(forTimeInterval: 5) }
                continue
            }

            guard let handle = FileHandle(forReadingAtPath: Self.logPath) else {
                if isRunning { Thread.sleep(forTimeInterval: 5) }
                continue
            }

            // Seek to end — we only care about new lines
            handle.seekToEndOfFile()
            let initialInode = Self.fileInode(Self.logPath)

            var buffer = ""

            while isRunning {
                let data = handle.availableData
                if data.isEmpty {
                    // Check for log rotation (inode changed)
                    if Self.fileInode(Self.logPath) != initialInode {
                        SplitTunnelEngine.shared.log("[SASELogWatcher] Log file rotated, re-opening")
                        break
                    }
                    Thread.sleep(forTimeInterval: 0.5)
                    continue
                }

                guard let text = String(data: data, encoding: .utf8) else { continue }
                buffer += text

                while let newlineRange = buffer.range(of: "\n") {
                    let line = String(buffer[buffer.startIndex..<newlineRange.lowerBound])
                    buffer = String(buffer[newlineRange.upperBound...])
                    processLine(line)
                }
            }

            try? handle.close()

            if isRunning {
                Thread.sleep(forTimeInterval: 1)
            }
        }
    }

    private func processLine(_ line: String) {
        // VPN connected signals
        if line.contains("vpnConnectionState=Connected") ||
           line.contains("onConnectedToVPN") {
            SplitTunnelEngine.shared.log("[SASELogWatcher] VPN connected signal detected")
            DispatchQueue.main.async { [weak self] in
                self?.onVPNConnected?()
            }
            return
        }

        // VPN disconnected signals
        if line.contains("vpnConnectionState=Disconnected") ||
           line.contains("vpnConnectionState=AwaitVPNConnector") ||
           line.contains("onDisconnectedFromVPN") {
            SplitTunnelEngine.shared.log("[SASELogWatcher] VPN disconnected signal detected")
            DispatchQueue.main.async { [weak self] in
                self?.onVPNDisconnected?()
            }
            return
        }
    }

    private static func fileInode(_ path: String) -> UInt64? {
        try? FileManager.default.attributesOfItem(atPath: path)[.systemFileNumber] as? UInt64
    }
}
