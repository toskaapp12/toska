//
//  DebugLog.swift
//  toska
//
//  IOS-11: release builds must not emit diagnostic logging. Every bare
//  print() in the app target routes through here; the call compiles to a
//  no-op outside DEBUG. Error paths that must survive to production
//  telemetry use Telemetry.recordError instead, not this.
//

func debugLog(_ items: Any...) {
    #if DEBUG
    print(items.map { "\($0)" }.joined(separator: " "))
    #endif
}
