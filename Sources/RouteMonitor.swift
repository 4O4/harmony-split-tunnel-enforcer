import Foundation

final class RouteMonitor {
    private var _process: Process?
    private var _isRunning = false
    private let lock = DispatchQueue(label: "com.harmony.routemonitor.lock")

    private var process: Process? {
        get { lock.sync { _process } }
        set { lock.sync { _process = newValue } }
    }

    private var isRunning: Bool {
        get { lock.sync { _isRunning } }
        set { lock.sync { _isRunning = newValue } }
    }

    /// Called on main thread when a route is added
    var onRouteAdded: (() -> Void)?

    /// Called on main thread when a route is deleted
    var onRouteDeleted: (() -> Void)?

    func start() {
        guard !isRunning else { return }
        isRunning = true

        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.runMonitor()
        }
    }

    func stop() {
        isRunning = false
        process?.terminate()
        process = nil
    }

    private func runMonitor() {
        while isRunning {
            let proc = Process()
            let pipe = Pipe()
            proc.executableURL = URL(fileURLWithPath: "/sbin/route")
            proc.arguments = ["-n", "monitor"]
            proc.standardOutput = pipe
            proc.standardError = FileHandle.nullDevice
            self.process = proc

            do {
                try proc.run()
            } catch {
                if isRunning {
                    Thread.sleep(forTimeInterval: 2)
                    continue
                }
                return
            }

            let handle = pipe.fileHandleForReading
            var buffer = ""

            while isRunning && proc.isRunning {
                let data = handle.availableData
                guard !data.isEmpty else { break }
                guard let text = String(data: data, encoding: .utf8) else { continue }

                buffer += text

                // Process complete lines
                while let newlineRange = buffer.range(of: "\n") {
                    let line = String(buffer[buffer.startIndex..<newlineRange.lowerBound])
                    buffer = String(buffer[newlineRange.upperBound...])
                    processLine(line)
                }
            }

            if isRunning {
                Thread.sleep(forTimeInterval: 1)
            }
        }
    }

    private func processLine(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Log all route monitor events
        SplitTunnelEngine.shared.log("[RouteMonitor] \(trimmed)")

        if trimmed.contains("RTM_ADD") {
            DispatchQueue.main.async { [weak self] in
                self?.onRouteAdded?()
            }
        }

        if trimmed.contains("RTM_DELETE") {
            DispatchQueue.main.async { [weak self] in
                self?.onRouteDeleted?()
            }
        }
    }
}
