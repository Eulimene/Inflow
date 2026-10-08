mod themes;

use std::env;
use std::error::Error;
use std::ffi::OsString;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::process::Command;

const GENERATED_HEADER: &str = "core/include/generated/inflow_core.h";
const XCFRAMEWORK_OUTPUT: &str = "build/InflowCore.xcframework";
const XCFRAMEWORK_TARGET: &str = "build/xcframework-target";

fn main() -> Result<(), Box<dyn Error>> {
    let command = env::args().nth(1).unwrap_or_else(|| "help".to_owned());
    let root = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .ok_or_else(|| io::Error::other("xtask has no repository parent"))?;

    match command.as_str() {
        "themes" => themes::build(root, false),
        "verify-themes" => themes::build(root, true),
        "bindings" => write_bindings(root),
        "verify-bindings" => verify_bindings(root),
        "test" => test_all(root),
        "xcframework" => build_xcframework(root),
        "verify" => {
            verify_bindings(root)?;
            test_all(root)
        }
        _ => {
            eprintln!(
                "usage: cargo xtask <themes|verify-themes|bindings|verify-bindings|test|xcframework|verify>"
            );
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

fn test_all(root: &Path) -> Result<(), Box<dyn Error>> {
    run(
        root,
        "cargo fmt (xtask)",
        [
            "fmt",
            "--manifest-path",
            "xtask/Cargo.toml",
            "--",
            "--check",
        ],
    )?;
    run(
        root,
        "cargo clippy (xtask)",
        [
            "clippy",
            "--manifest-path",
            "xtask/Cargo.toml",
            "--locked",
            "--all-targets",
            "--",
            "-D",
            "warnings",
        ],
    )?;
    themes::build(root, true)?;
    run(
        root,
        "cargo test (xtask)",
        ["test", "--manifest-path", "xtask/Cargo.toml", "--locked"],
    )?;
    test_core(root)
}

fn build_xcframework(root: &Path) -> Result<(), Box<dyn Error>> {
    verify_bindings(root)?;

    let target_dir = root.join(XCFRAMEWORK_TARGET);
    let staging_dir = root.join("build/xcframework-staging");
    let output = root.join(XCFRAMEWORK_OUTPUT);
    let manifest = root.join("core/Cargo.toml");

    for target in ["aarch64-apple-darwin", "x86_64-apple-darwin"] {
        let mut command = cargo_command();
        command
            .args([
                "build",
                "--manifest-path",
                manifest
                    .to_str()
                    .ok_or_else(|| io::Error::other("non-UTF-8 core manifest path"))?,
                "--locked",
                "--release",
                "--target",
                target,
            ])
            .env("CARGO_TARGET_DIR", &target_dir)
            .env("MACOSX_DEPLOYMENT_TARGET", "14.0")
            .current_dir(root);
        run_command(&mut command, &format!("cargo build for {target}"))?;
    }

    if staging_dir.exists() {
        fs::remove_dir_all(&staging_dir)?;
    }
    fs::create_dir_all(&staging_dir)?;
    let universal_library = staging_dir.join("libinflow_core.a");
    let arm_library = release_library(&target_dir, "aarch64-apple-darwin");
    let intel_library = release_library(&target_dir, "x86_64-apple-darwin");
    let mut lipo = Command::new("xcrun");
    lipo.args(["lipo", "-create"])
        .arg(&arm_library)
        .arg(&intel_library)
        .arg("-output")
        .arg(&universal_library)
        .current_dir(root);
    run_command(&mut lipo, "create universal static library")?;

    if output.exists() {
        fs::remove_dir_all(&output)?;
    }
    let mut create = Command::new("xcodebuild");
    create
        .arg("-create-xcframework")
        .arg("-library")
        .arg(&universal_library)
        .arg("-headers")
        .arg(root.join("core/include"))
        .arg("-output")
        .arg(&output)
        .current_dir(root);
    run_command(&mut create, "create XCFramework")?;

    println!("created {}", output.display());
    Ok(())
}

fn release_library(target_dir: &Path, target: &str) -> PathBuf {
    target_dir.join(target).join("release/libinflow_core.a")
}

fn run_command(command: &mut Command, label: &str) -> Result<(), Box<dyn Error>> {
    let status = command.status()?;
    if status.success() {
        Ok(())
    } else {
        Err(io::Error::other(format!("{label} failed with {status}")).into())
    }
}

fn run<const N: usize>(
    root: &Path,
    label: &str,
    arguments: [&str; N],
) -> Result<(), Box<dyn Error>> {
    let status = cargo_command().args(arguments).current_dir(root).status()?;
    if status.success() {
        Ok(())
    } else {
        Err(io::Error::other(format!("{label} failed with {status}")).into())
    }
}

fn cargo_command() -> Command {
    Command::new(env::var_os("CARGO").unwrap_or_else(|| OsString::from("cargo")))
}
