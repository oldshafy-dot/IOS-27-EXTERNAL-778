import Foundation

/// Device-side adapter: bridges the C probe to the pure model layer.
///
/// Kept apart from `IOSurfaceUAFProbe.swift` so the policy tests can compile
/// the model without the IOKit bridging header.
extension IOSurfaceUAFResult {
    init(raw: isurf_uaf_result) {
        let serviceFound = raw.service_found != 0
        let shape = Int(raw.shape)
        let ok = Int(raw.ok)
        let total = Int(raw.total)
        let verdict = IOSurfaceUAFProbe.verdict(
            serviceFound: serviceFound,
            shape: shape,
            ok: ok,
            total: total
        )
        let codes: IOSurfaceUAFFailCodes? = raw.had_failure != 0
            ? IOSurfaceUAFFailCodes(
                sel17: raw.first_fail_17,
                dup: raw.first_fail_dup,
                sel18: raw.first_fail_18,
                re17: raw.first_fail_re17
            )
            : nil
        self.init(
            verdict: verdict,
            ok: ok,
            total: total,
            shape: shape,
            timedOut: raw.timed_out != 0,
            elapsedMS: raw.elapsed_ms,
            failCodes: codes,
            osVersion: AppInfo.osVersion,
            build: AppInfo.cachedOSBuild,
            machine: AppInfo.machineName,
            at: Date()
        )
    }

    /// Returned when the C entry point rejects its argument (should not
    /// happen; keeps the UI honest instead of crashing).
    static var unavailableFallback: IOSurfaceUAFResult {
        IOSurfaceUAFResult(
            verdict: .serviceMissing,
            ok: 0,
            total: 0,
            shape: -1,
            timedOut: false,
            elapsedMS: 0,
            failCodes: nil,
            osVersion: AppInfo.osVersion,
            build: AppInfo.cachedOSBuild,
            machine: AppInfo.machineName,
            at: Date()
        )
    }
}

enum IOSurfaceUAFRunner {
    /// Runs the probe off the main thread and delivers the result on main.
    nonisolated static func run(completion: @escaping (IOSurfaceUAFResult) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            var raw = isurf_uaf_result()
            let rc = isurf_uaf_probe(&raw)
            let result = rc == 0
                ? IOSurfaceUAFResult(raw: raw)
                : IOSurfaceUAFResult.unavailableFallback
            IOSurfaceUAFProbe.store(result)
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }
}
