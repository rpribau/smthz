import Darwin

extension HostSessionExit {
    /// Human-readable exit for display only ("exit 0", "signal 9 (SIGKILL)"); the wire format is unchanged.
    public var displayDescription: String {
        if let code { return "exit \(code)" }
        if let signal {
            guard let name = Self.signalName(signal) else { return "signal \(signal)" }
            return "signal \(signal) (\(name))"
        }
        return "running"
    }

    static func signalName(_ signal: Int32) -> String? {
        guard signal > 0, signal < NSIG else { return nil }
        return withUnsafePointer(to: sys_signame) { table in
            table.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: Int(NSIG)) { names in
                names[Int(signal)].map { "SIG" + String(cString: $0).uppercased() }
            }
        }
    }
}
