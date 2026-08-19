//! Cross-platform document core for Inflow.
//!
//! Platform clients communicate with this crate through the versioned C ABI.

mod document;
mod ffi;

/// Current version of the C ABI exposed to platform clients.
pub const ABI_VERSION: u32 = 1;

/// Returns the version of the C ABI implemented by this library.
#[unsafe(no_mangle)]
pub extern "C" fn inflow_core_abi_version() -> u32 {
    ABI_VERSION
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exported_abi_version_matches_public_contract() {
        assert_eq!(inflow_core_abi_version(), ABI_VERSION);
    }
}
