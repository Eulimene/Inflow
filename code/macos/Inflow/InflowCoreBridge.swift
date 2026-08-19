import Foundation

enum InflowCoreBridge {
    static var abiVersion: UInt32 {
        inflow_core_abi_version()
    }

    static var isCompatible: Bool {
        abiVersion == 1
    }
}
