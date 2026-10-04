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
        static let enginePersistence = Self(
            rawValue: UInt64(INFLOW_CAPABILITY_ENGINE_PERSISTENCE)
        )
        static let engineMode = Self(rawValue: UInt64(INFLOW_CAPABILITY_ENGINE_MODE))
        static let hostEffects = Self(rawValue: UInt64(INFLOW_CAPABILITY_HOST_EFFECTS))
        static let documentCodec = Self(rawValue: UInt64(INFLOW_CAPABILITY_DOCUMENT_CODEC))
        static let portablePresentation = Self(rawValue: UInt64(INFLOW_CAPABILITY_PORTABLE_PRESENTATION))

        static let editorRequired: Self = [
            .editorEngine,
            .unifiedDerivation,
            .engineHistory,
            .renderIR,
            .nativeRenderPlan,
            .engineSearch,
            .formatInspection,
            .enginePersistence,
            .engineMode,
            .hostEffects,
            .documentCodec,
            .portablePresentation,
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
        abiMajor == 3 && capabilities.isSuperset(of: .editorRequired)
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
