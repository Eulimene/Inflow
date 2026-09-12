//! Cross-platform document core for Inflow.
//!
//! Platform clients communicate with this crate through the versioned C ABI.

mod analysis;
mod code_highlight;
mod document;
mod engine;
mod export;
mod ffi;
mod format;
mod highlight;
mod markdown_ir;
mod math;
mod mermaid;
mod reference;
mod render;
mod render_ir;
mod search;

/// Current compatibility coordinates for the C ABI exposed to platform clients.
pub const ABI_MAJOR: u32 = 2;
pub const ABI_MINOR: u32 = 1;

/// Capability bits let clients require additive contracts without rejecting a
/// compatible library merely because its minor version is newer.
pub const CAPABILITY_EDITOR_ENGINE: u64 = 1 << 0;
pub const CAPABILITY_UNIFIED_DERIVATION: u64 = 1 << 1;
pub const CAPABILITY_ENGINE_HISTORY: u64 = 1 << 2;
pub const CAPABILITY_RENDER_IR: u64 = 1 << 3;
pub const ABI_CAPABILITIES: u64 = CAPABILITY_EDITOR_ENGINE
    | CAPABILITY_UNIFIED_DERIVATION
    | CAPABILITY_ENGINE_HISTORY
    | CAPABILITY_RENDER_IR;

/// Returns the version of the C ABI implemented by this library.
#[unsafe(no_mangle)]
pub extern "C" fn inflow_core_abi_version() -> u32 {
    ABI_MAJOR
}

/// Returns the incompatible-change coordinate of the C ABI.
#[unsafe(no_mangle)]
pub extern "C" fn inflow_core_abi_major() -> u32 {
    ABI_MAJOR
}

/// Returns the additive-change coordinate of the C ABI.
#[unsafe(no_mangle)]
pub extern "C" fn inflow_core_abi_minor() -> u32 {
    ABI_MINOR
}

/// Returns the additive contracts implemented by this library.
#[unsafe(no_mangle)]
pub extern "C" fn inflow_core_capabilities() -> u64 {
    ABI_CAPABILITIES
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exported_abi_version_matches_public_contract() {
        assert_eq!(inflow_core_abi_version(), ABI_MAJOR);
        assert_eq!(inflow_core_abi_major(), ABI_MAJOR);
        assert_eq!(inflow_core_abi_minor(), ABI_MINOR);
        assert_eq!(inflow_core_capabilities(), ABI_CAPABILITIES);
        assert_ne!(ABI_CAPABILITIES & CAPABILITY_EDITOR_ENGINE, 0);
        assert_ne!(ABI_CAPABILITIES & CAPABILITY_UNIFIED_DERIVATION, 0);
        assert_ne!(ABI_CAPABILITIES & CAPABILITY_ENGINE_HISTORY, 0);
        assert_ne!(ABI_CAPABILITIES & CAPABILITY_RENDER_IR, 0);
    }
}
