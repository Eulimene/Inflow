import Foundation

enum InflowCoreBridgeError: Error {
    case invalidOwnedBytes
}

enum InflowCoreBridge {
    struct Capabilities: OptionSet {
        let rawValue: UInt64

        static let editorEngine = Self(rawValue: UInt64(INFLOW_CAPABILITY_EDITOR_ENGINE))
        static let unifiedDerivation = Self(rawValue: UInt64(INFLOW_CAPABILITY_UNIFIED_DERIVATION))
        static let engineHistory = Self(rawValue: UInt64(INFLOW_CAPABILITY_ENGINE_HISTORY))
        static let renderIR = Self(rawValue: UInt64(INFLOW_CAPABILITY_RENDER_IR))
        static let nativeRenderPlan = Self(
            rawValue: UInt64(INFLOW_CAPABILITY_NATIVE_RENDER_PLAN)
        )
        static let engineSearch = Self(rawValue: UInt64(INFLOW_CAPABILITY_ENGINE_SEARCH))
        static let formatInspection = Self(
            rawValue: UInt64(INFLOW_CAPABILITY_FORMAT_INSPECTION)
        )

        static let editorRequired: Self = [
            .editorEngine,
            .unifiedDerivation,
            .engineHistory,
            .renderIR,
            .nativeRenderPlan,
            .engineSearch,
            .formatInspection,
        ]
    }

    static var abiMajor: UInt32 {
        inflow_core_abi_major()
    }

    static var abiMinor: UInt32 {
        inflow_core_abi_minor()
    }

    static var abiVersion: UInt32 {
        inflow_core_abi_version()
    }

    static var capabilities: Capabilities {
        Capabilities(rawValue: inflow_core_capabilities())
    }

    static var isCompatible: Bool {
        abiMajor == 2 && capabilities.isSuperset(of: .editorRequired)
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
