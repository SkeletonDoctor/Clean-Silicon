import Foundation

/// Thin runtime binding to the private IOReport library (the same source Activity Monitor
/// and powermetrics read from). Loaded with dlopen so the app still launches if it is missing.
final class IOReportSampler {
    struct Channel {
        let group: String
        let subgroup: String
        let name: String
        let unit: String
        let value: Int64
        let states: [(name: String, residency: Int64)]
    }

    private typealias CopyChannelsFn = @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
    private typealias MergeFn = @convention(c) (CFMutableDictionary, CFMutableDictionary, CFTypeRef?) -> Void
    private typealias SubscribeFn = @convention(c) (UnsafeRawPointer?, CFMutableDictionary, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>, UInt64, CFTypeRef?) -> UnsafeRawPointer?
    private typealias SamplesFn = @convention(c) (UnsafeRawPointer?, CFMutableDictionary?, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias DeltaFn = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias StringFn = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias IntFn = @convention(c) (CFDictionary, Int32) -> Int64
    private typealias CountFn = @convention(c) (CFDictionary) -> Int32
    private typealias StateNameFn = @convention(c) (CFDictionary, Int32) -> Unmanaged<CFString>?

    private let createSamples: SamplesFn
    private let createDelta: DeltaFn
    private let getGroup: StringFn
    private let getSubGroup: StringFn
    private let getName: StringFn
    private let getUnit: StringFn
    private let getInteger: IntFn
    private let stateCount: CountFn
    private let stateName: StateNameFn
    private let stateResidency: IntFn

    private let subscription: UnsafeRawPointer
    private let subscribed: CFMutableDictionary
    private var previous: (sample: CFDictionary, time: TimeInterval)?

    init?(groups: [(String, String?)]) {
        guard let lib = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) else { return nil }
        func sym<T>(_ name: String, as type: T.Type) -> T? {
            guard let p = dlsym(lib, name) else { return nil }
            return unsafeBitCast(p, to: T.self)
        }
        guard
            let copy = sym("IOReportCopyChannelsInGroup", as: CopyChannelsFn.self),
            let merge = sym("IOReportMergeChannels", as: MergeFn.self),
            let subscribe = sym("IOReportCreateSubscription", as: SubscribeFn.self),
            let samples = sym("IOReportCreateSamples", as: SamplesFn.self),
            let delta = sym("IOReportCreateSamplesDelta", as: DeltaFn.self),
            let group = sym("IOReportChannelGetGroup", as: StringFn.self),
            let subgroup = sym("IOReportChannelGetSubGroup", as: StringFn.self),
            let name = sym("IOReportChannelGetChannelName", as: StringFn.self),
            let unit = sym("IOReportChannelGetUnitLabel", as: StringFn.self),
            let integer = sym("IOReportSimpleGetIntegerValue", as: IntFn.self),
            let count = sym("IOReportStateGetCount", as: CountFn.self),
            let sName = sym("IOReportStateGetNameForIndex", as: StateNameFn.self),
            let sRes = sym("IOReportStateGetResidency", as: IntFn.self)
        else { return nil }

        createSamples = samples; createDelta = delta
        getGroup = group; getSubGroup = subgroup; getName = name; getUnit = unit
        getInteger = integer; stateCount = count; stateName = sName; stateResidency = sRes

        var merged: CFMutableDictionary?
        for (g, s) in groups {
            guard let chans = copy(g as CFString, s as CFString?, 0, 0, 0)?.takeRetainedValue() else { continue }
            if let m = merged { merge(m, chans, nil) } else { merged = chans }
        }
        guard let all = merged else { return nil }
        var out: Unmanaged<CFMutableDictionary>?
        guard let sub = subscribe(nil, all, &out, 0, nil), let subbed = out?.takeRetainedValue() else { return nil }
        subscription = sub
        subscribed = subbed
    }

    /// Returns the channel deltas since the previous call, plus the elapsed seconds.
    func sample() -> (channels: [Channel], dt: TimeInterval)? {
        guard let now = createSamples(subscription, subscribed, nil)?.takeRetainedValue() else { return nil }
        let t = ProcessInfo.processInfo.systemUptime
        defer { previous = (now, t) }
        guard let prev = previous, t > prev.time,
              let delta = createDelta(prev.sample, now, nil)?.takeRetainedValue(),
              let items = (delta as NSDictionary)["IOReportChannels"] as? [NSDictionary] else { return nil }

        var result: [Channel] = []
        result.reserveCapacity(items.count)
        for item in items {
            let d = item as CFDictionary
            func str(_ f: StringFn) -> String { (f(d)?.takeUnretainedValue() as String?) ?? "" }
            let n = stateCount(d)
            var states: [(String, Int64)] = []
            if n > 0 {
                for i in 0..<n {
                    let sn = (stateName(d, i)?.takeUnretainedValue() as String?) ?? ""
                    states.append((sn, stateResidency(d, i)))
                }
            }
            result.append(Channel(group: str(getGroup), subgroup: str(getSubGroup), name: str(getName),
                                  unit: str(getUnit).trimmingCharacters(in: .whitespaces),
                                  value: n > 0 ? 0 : getInteger(d, 0), states: states))
        }
        return (result, t - prev.time)
    }
}
