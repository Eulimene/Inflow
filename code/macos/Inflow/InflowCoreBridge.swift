import Foundation

enum InflowCoreBridgeError: Error {
    case invalidOwnedBytes
}

enum InflowCoreBridge {
    static var abiVersion: UInt32 {
        inflow_core_abi_version()
    }

    static var isCompatible: Bool {
        abiVersion == 1
    }

    static func copyAndFree(_ bytes: InflowOwnedBytes) throws -> Data {
        defer { inflow_owned_bytes_free(bytes.data, bytes.length) }

        guard bytes.length > 0 else {
            return Data()
        }
        guard let pointer = bytes.data, bytes.length <= UInt(Int.max) else {
            throw InflowCoreBridgeError.invalidOwnedBytes
        }
        return Data(bytes: pointer, count: Int(bytes.length))
    }
}
