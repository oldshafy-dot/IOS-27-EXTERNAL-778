import Foundation

/// Verdict of the read-only IOSurfaceRoot registry probe (CVE-2026-112477).
///
/// Pure model layer: no IOKit or C bridging lives here, so `Tests/main.swift`
/// can compile this file with `swiftc` and exercise the mapping on macOS.
enum IOSurfaceUAFVerdict: String, Equatable {
    /// All 120 iterations matched: the registry is fully controllable from
    /// userspace. This is the UAF's precondition, NOT proof of exploitability.
    case controllable
    case partial
    case unavailable
    case serviceMissing

    var localizationKey: String {
        switch self {
        case .controllable: return "diag.uaf.controllable"
        case .partial: return "diag.uaf.partial"
        case .unavailable: return "diag.uaf.unavailable"
        case .serviceMissing: return "diag.uaf.service_missing"
        }
    }
}

struct IOSurfaceUAFFailCodes: Equatable {
    let sel17: UInt32
    let dup: UInt32
    let sel18: UInt32
    let re17: UInt32

    var summary: String {
        String(format: "17=0x%X dup=0x%X 18=0x%X re17=0x%X", sel17, dup, sel18, re17)
    }
}

struct IOSurfaceUAFResult: Equatable {
    let verdict: IOSurfaceUAFVerdict
    let ok: Int
    let total: Int
    let shape: Int
    let timedOut: Bool
    let elapsedMS: UInt64
    let failCodes: IOSurfaceUAFFailCodes?
    let osVersion: String
    let build: String
    let machine: String
    let at: Date

    var detail: String {
        var parts = ["\(ok)/\(total)", "shape=\(shape)", "\(elapsedMS)ms"]
        if timedOut { parts.append("timeout") }
        if let failCodes { parts.append(failCodes.summary) }
        return parts.joined(separator: ", ")
    }
}

enum IOSurfaceUAFProbe {
    static let iterations = 120

    /// Maps the raw counters to a verdict. Pure and testable.
    static func verdict(
        serviceFound: Bool,
        shape: Int,
        ok: Int,
        total: Int
    ) -> IOSurfaceUAFVerdict {
        guard serviceFound else { return .serviceMissing }
        guard shape >= 0, total > 0 else { return .unavailable }
        if ok == iterations && total == iterations { return .controllable }
        if ok > 0 { return .partial }
        return .unavailable
    }

    /// The one-line report used by `SandboxDiagnostics.exportText()`.
    static func exportLine(_ result: IOSurfaceUAFResult?) -> String {
        guard let result else { return "IOSurface UAF: not-run" }
        return "IOSurface UAF: \(result.verdict.rawValue) (\(result.detail)) "
            + "build=\(result.build) device=\(result.machine)"
    }

    // MARK: - Last result (report channel)

    private static let lock = NSLock()
    private static var stored: IOSurfaceUAFResult?

    static var lastResult: IOSurfaceUAFResult? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    static func store(_ result: IOSurfaceUAFResult) {
        lock.lock()
        defer { lock.unlock() }
        stored = result
    }
}
