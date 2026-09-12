use std::env;
use std::error::Error;
use std::fs;
use std::io;
use std::path::Path;
use std::process::Command;

const GENERATED_HEADER: &str = "core/include/generated/inflow_core.h";

fn main() -> Result<(), Box<dyn Error>> {
    let command = env::args().nth(1).unwrap_or_else(|| "help".to_owned());
    let root = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .ok_or_else(|| io::Error::other("xtask has no repository parent"))?;

    match command.as_str() {
        "bindings" => write_bindings(root),
        "verify-bindings" => verify_bindings(root),
        "test" => test_core(root),
        "verify" => {
            verify_bindings(root)?;
            test_core(root)
        }
        _ => {
            eprintln!("usage: cargo xtask <bindings|verify-bindings|test|verify>");
            Ok(())
        }
    }
}

fn generated_bindings(root: &Path) -> Result<Vec<u8>, Box<dyn Error>> {
    let core = root.join("core");
    let config =
        cbindgen::Config::from_file(core.join("cbindgen.toml")).map_err(io::Error::other)?;
    let bindings = cbindgen::generate_with_config(&core, config)?;
    let mut output = Vec::new();
    bindings.write(&mut output);
    Ok(output)
}

fn write_bindings(root: &Path) -> Result<(), Box<dyn Error>> {
    let path = root.join(GENERATED_HEADER);
    let output = generated_bindings(root)?;
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    fs::write(&path, output)?;
    println!("generated {}", path.display());
    Ok(())
}

fn verify_bindings(root: &Path) -> Result<(), Box<dyn Error>> {
    let path = root.join(GENERATED_HEADER);
    let expected = fs::read(&path).map_err(|error| {
        io::Error::new(
            error.kind(),
            format!("cannot read generated header {}: {error}", path.display()),
        )
    })?;
    let actual = generated_bindings(root)?;
    if expected != actual {
        return Err(
            io::Error::other("generated bindings are stale; run `cargo xtask bindings`").into(),
        );
    }
    println!("verified {}", path.display());
    Ok(())
}

fn test_core(root: &Path) -> Result<(), Box<dyn Error>> {
    run(
        root,
        "cargo fmt",
        ["fmt", "--manifest-path", "core/Cargo.toml", "--", "--check"],
    )?;
    run(
        root,
        "cargo clippy",
        [
            "clippy",
            "--manifest-path",
            "core/Cargo.toml",
            "--locked",
            "--all-targets",
            "--all-features",
            "--",
            "-D",
            "warnings",
        ],
    )?;
    run(
        root,
        "cargo test",
        [
            "test",
            "--manifest-path",
            "core/Cargo.toml",
            "--locked",
            "--all-targets",
        ],
    )
}

fn run<const N: usize>(
    root: &Path,
    label: &str,
    arguments: [&str; N],
) -> Result<(), Box<dyn Error>> {
    let status = Command::new("cargo")
        .args(arguments)
        .current_dir(root)
        .status()?;
    if status.success() {
        Ok(())
    } else {
        Err(io::Error::other(format!("{label} failed with {status}")).into())
    }
}
