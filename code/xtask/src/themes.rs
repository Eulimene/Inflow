//! SCSS is an authoring format only. Runtime and all OS hosts receive identical CSS.
use std::collections::BTreeSet;
use std::error::Error;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

const HEADER: &str = "/* Generated from ThemeSources; do not edit. Run `cargo xtask themes`. */\n";

type Outputs = Vec<(PathBuf, Vec<u8>)>;

fn files_with_extension(root: &Path, extension: &str) -> io::Result<Vec<PathBuf>> {
    fn visit(root: &Path, dir: &Path, extension: &str, paths: &mut Vec<PathBuf>) -> io::Result<()> {
        for entry in fs::read_dir(dir)? {
            let entry = entry?;
            let kind = entry.file_type()?;
            if kind.is_dir() {
                visit(root, &entry.path(), extension, paths)?;
            } else if kind.is_file() && entry.path().extension().is_some_and(|e| e == extension) {
                paths.push(entry.path().strip_prefix(root).unwrap().to_owned());
            }
        }
        Ok(())
    }
    let mut paths = Vec::new();
    visit(root, root, extension, &mut paths)?;
    paths.sort();
    Ok(paths)
}

fn compile(source: &Path) -> Result<Outputs, Box<dyn Error>> {
    let options = grass::Options::default().style(grass::OutputStyle::Expanded);
    let mut outputs = Vec::new();
    for relative in files_with_extension(source, "scss")? {
        if relative
            .file_name()
            .unwrap()
            .to_string_lossy()
            .starts_with('_')
        {
            continue;
        }
        let css = grass::from_path(source.join(&relative), &options)?;
        outputs.push((
            relative.with_extension("css"),
            format!("{HEADER}{css}").into_bytes(),
        ));
    }
    if outputs.is_empty() {
        return Err(io::Error::other("no SCSS entry points found").into());
    }
    Ok(outputs)
}

/// Compile every entry before writing anything; a syntax error cannot leave a
/// mixture of old and new themes. Unchanged files retain timestamps so native
/// builds and installed-theme fingerprint migrations don't churn.
pub fn build(root: &Path, verify_only: bool) -> Result<(), Box<dyn Error>> {
    let outputs = compile(&root.join("ThemeSources"))?;
    let destination = root.join("Themes");
    let expected: BTreeSet<_> = outputs.iter().map(|(path, _)| path.clone()).collect();
    for path in files_with_extension(&destination, "css")? {
        if !expected.contains(&path) {
            return Err(io::Error::other(format!(
                "CSS without SCSS source: {} (remove obsolete output explicitly)",
                path.display()
            ))
            .into());
        }
    }
    let mut changed = 0;
    for (relative, bytes) in outputs {
        let path = destination.join(relative);
        // Git may check tracked text out with CRLF on Windows.
        let current = fs::read_to_string(&path)
            .ok()
            .map(|s| s.replace("\r\n", "\n"));
        if current.as_ref().map(|s| s.as_bytes()) == Some(bytes.as_slice()) {
            continue;
        }
        if verify_only {
            return Err(io::Error::other(format!(
                "stale generated CSS: {}; run `cargo xtask themes`",
                path.display()
            ))
            .into());
        }
        fs::create_dir_all(path.parent().unwrap())?;
        fs::write(path, bytes)?;
        changed += 1;
    }
    println!(
        "{} SCSS theme outputs ({changed} changed)",
        if verify_only { "verified" } else { "compiled" }
    );
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};
    static NEXT: AtomicUsize = AtomicUsize::new(0);
    struct Fixture(PathBuf);
    impl Fixture {
        fn new() -> Self {
            let root = std::env::temp_dir().join(format!(
                "inflow-scss-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            fs::create_dir_all(root.join("ThemeSources/Base")).unwrap();
            fs::create_dir_all(root.join("Themes")).unwrap();
            fs::write(root.join("ThemeSources/_shared.scss"), "$ink: #123456;").unwrap();
            fs::write(
                root.join("ThemeSources/paper.scss"),
                "@use 'shared'; body { color: shared.$ink; }",
            )
            .unwrap();
            fs::write(
                root.join("ThemeSources/Base/default.scss"),
                "body { line-height: 1.6; }",
            )
            .unwrap();
            Self(root)
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn shared_changes_rebuild_entries_and_verify_never_writes() {
        let f = Fixture::new();
        build(&f.0, false).unwrap();
        let output = f.0.join("Themes/paper.css");
        assert!(!f.0.join("Themes/_shared.css").exists());
        assert!(f.0.join("Themes/Base/default.css").exists());
        let before = fs::read(&output).unwrap();
        let modified = fs::metadata(&output).unwrap().modified().unwrap();
        build(&f.0, false).unwrap();
        assert_eq!(modified, fs::metadata(&output).unwrap().modified().unwrap());
        build(&f.0, true).unwrap();
        fs::write(f.0.join("ThemeSources/_shared.scss"), "$ink: #abcdef;").unwrap();
        assert!(build(&f.0, true).is_err());
        assert_eq!(before, fs::read(&output).unwrap());
        build(&f.0, false).unwrap();
        assert!(fs::read_to_string(output).unwrap().contains("#abcdef"));
    }

    #[test]
    fn invalid_scss_preserves_existing_outputs_and_orphans_are_reported() {
        let f = Fixture::new();
        build(&f.0, false).unwrap();
        let before = fs::read(f.0.join("Themes/paper.css")).unwrap();
        fs::write(f.0.join("ThemeSources/paper.scss"), "body { color: red; }").unwrap();
        fs::write(f.0.join("ThemeSources/z-broken.scss"), "body {").unwrap();
        assert!(build(&f.0, false).is_err());
        assert_eq!(before, fs::read(f.0.join("Themes/paper.css")).unwrap());
        fs::remove_file(f.0.join("ThemeSources/z-broken.scss")).unwrap();
        fs::write(f.0.join("Themes/obsolete.css"), "body {}").unwrap();
        assert!(build(&f.0, true).is_err());
    }

    #[test]
    fn checked_in_themes_are_reproducible() {
        build(
            Path::new(env!("CARGO_MANIFEST_DIR")).parent().unwrap(),
            true,
        )
        .unwrap();
    }
}
