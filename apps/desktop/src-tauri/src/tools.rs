//! The two jobs the editor cannot do inside its page: compiling a figure (LaTeX) and printing a
//! PDF (headless Chrome). Each is one run of the `sb` command-line tool: no server is started and
//! nothing keeps running. Without the tool the editor still works: figures stay placeholders that
//! say what is missing, and PDF export reports it.
//!
//! The tool is `$SB_BIN`, else `sb` beside this executable, else `sb` on `PATH`. On Windows
//! without a native `sb.exe` it is the Linux one inside WSL, started through
//! `~/.local/bin/slideblaster-tool` there, when the project folder is one WSL can see.

use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};

/// One argument of a tool run; paths are rewritten when the tool runs inside WSL.
pub enum Arg<'a> {
    Text(&'a str),
    Path(&'a Path),
}

fn sb_binary() -> PathBuf {
    if let Some(p) = std::env::var_os("SB_BIN") {
        return PathBuf::from(p);
    }
    if let Ok(exe) = std::env::current_exe() {
        let beside = exe.with_file_name(if cfg!(windows) { "sb.exe" } else { "sb" });
        if beside.exists() {
            return beside;
        }
    }
    PathBuf::from("sb")
}

/// The editor's web bundle on disk, for the tool's offline viewer: `$SB_WEB`, else the repository's.
fn web_dir() -> Option<PathBuf> {
    let dir = std::env::var_os("SB_WEB").map(PathBuf::from).unwrap_or_else(|| Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../hosts/web"));
    dir.is_dir().then_some(dir)
}

/// A Windows path as Linux inside WSL sees it, with the distribution when the path names one:
/// `\\wsl.localhost\Ubuntu\home\me\talk` is `/home/me/talk` in `Ubuntu`, `C:\talks\a` is
/// `/mnt/c/talks/a` in whichever distribution runs. Other paths have no Linux form.
#[cfg(any(windows, test))]
pub fn wsl_path(path: &str) -> Option<(Option<String>, String)> {
    let plain = path.replace('/', "\\");
    let plain = match plain.strip_prefix("\\\\?\\UNC\\") {
        Some(rest) => format!("\\\\{rest}"),
        None => plain.strip_prefix("\\\\?\\").unwrap_or(&plain).to_string(),
    };
    let lower = plain.to_ascii_lowercase();
    for host in ["\\\\wsl.localhost\\", "\\\\wsl$\\"] {
        if lower.starts_with(host) {
            let rest = &plain[host.len()..];
            let (distro, inside) = rest.split_once('\\').unwrap_or((rest, ""));
            if distro.is_empty() {
                return None;
            }
            let linux = format!("/{}", inside.replace('\\', "/"));
            let linux = if linux.len() > 1 { linux.trim_end_matches('/').to_string() } else { linux };
            return Some((Some(distro.to_string()), linux));
        }
    }
    let bytes = plain.as_bytes();
    if bytes.len() >= 2 && bytes[0].is_ascii_alphabetic() && bytes[1] == b':' {
        let inside = plain[2..].replace('\\', "/");
        let linux = format!("/mnt/{}{}", (bytes[0] as char).to_ascii_lowercase(), inside);
        return Some((None, linux.trim_end_matches('/').to_string()));
    }
    None
}

/// The command for one tool run in a project folder.
fn tool_command(folder: &Path, args: &[Arg]) -> Result<Command, String> {
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const NO_WINDOW: u32 = 0x0800_0000;
        let native = sb_binary();
        if std::env::var_os("SB_BIN").is_none() && !native.is_file() {
            let (distro, _) = wsl_path(&folder.to_string_lossy()).ok_or("no sb tool: this folder is not one WSL can see, and there is no sb.exe beside the app")?;
            let mut command = Command::new("wsl.exe");
            if let Some(distro) = distro {
                command.args(["-d", &distro]);
            }
            command.args(["-e", "sh", "-c", "exec \"$HOME/.local/bin/slideblaster-tool\" \"$@\"", "sh"]);
            for arg in args {
                match arg {
                    Arg::Text(text) => command.arg(text),
                    Arg::Path(path) => command.arg(wsl_path(&path.to_string_lossy()).ok_or("a path WSL cannot see")?.1),
                };
            }
            command.creation_flags(NO_WINDOW);
            return Ok(command);
        }
        let mut command = Command::new(native);
        command.creation_flags(NO_WINDOW);
        for arg in args {
            match arg {
                Arg::Text(text) => command.arg(text),
                Arg::Path(path) => command.arg(path),
            };
        }
        return Ok(command);
    }
    #[cfg(not(windows))]
    {
        let _ = folder;
        let mut command = Command::new(sb_binary());
        for arg in args {
            match arg {
                Arg::Text(text) => command.arg(text),
                Arg::Path(path) => command.arg(path),
            };
        }
        Ok(command)
    }
}

fn run(folder: &Path, args: &[Arg], input: &[u8]) -> Result<Output, String> {
    let mut child = tool_command(folder, args)?
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("could not run the sb tool ({e})"))?;
    if let Some(mut stdin) = child.stdin.take() {
        // A tool that does not read its input (a failed start) closes the pipe: not an error here.
        let _ = stdin.write_all(input);
    }
    child.wait_with_output().map_err(|e| e.to_string())
}

/// Compile one figure: a `block.render` request in, a `provider_result` body out (both JSON).
pub fn render_block(folder: &Path, request: &str) -> Result<String, String> {
    let output = run(folder, &[Arg::Text("render"), Arg::Path(folder)], request.as_bytes())?;
    let text = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if !output.status.success() || !text.starts_with('{') {
        let why = String::from_utf8_lossy(&output.stderr).lines().last().unwrap_or("it printed nothing").to_string();
        return Err(format!("the sb tool could not compile the figure: {why}"));
    }
    Ok(text)
}

/// A Windows path without its `\\?\` long-path prefix, which Explorer and people do not read.
pub fn plain_path(path: &Path) -> String {
    let text = path.to_string_lossy();
    match text.strip_prefix(r"\\?\UNC\") {
        Some(rest) => format!(r"\\{rest}"),
        None => text.strip_prefix(r"\\?\").unwrap_or(&text).to_string(),
    }
}

/// Where `sb build --pdf` writes a deck's PDF: beside the deck, named after it.
pub fn pdf_path(deck: &Path) -> PathBuf {
    let name = deck.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    let stem = name.strip_suffix(".slideBlaster.md").or_else(|| name.strip_suffix(".tikz")).unwrap_or(&name);
    deck.with_file_name(format!("{stem}.pdf"))
}

/// Print the deck to `pdf_path`; the tool's warnings (content out of bounds) on success.
pub fn export_pdf(folder: &Path, deck: &Path, steps: bool) -> Result<Vec<String>, String> {
    let out = pdf_path(deck);
    let web = web_dir();
    let mut args = vec![Arg::Text("build"), Arg::Text("--pdf"), Arg::Path(deck), Arg::Text("-o"), Arg::Path(&out)];
    if steps {
        args.push(Arg::Text("--steps"));
    }
    // Inside WSL the starter script names the web bundle itself.
    if let (Some(web), false) = (&web, cfg!(windows)) {
        args.push(Arg::Text("--web"));
        args.push(Arg::Path(web));
    }
    let output = run(folder, &args, b"")?;
    let said = format!("{}\n{}", String::from_utf8_lossy(&output.stdout), String::from_utf8_lossy(&output.stderr));
    if !output.status.success() {
        return Err(said.lines().filter(|l| !l.trim().is_empty()).last().unwrap_or("the sb tool failed").to_string());
    }
    Ok(said.lines().filter_map(|l| l.strip_prefix("warning: out of bounds: ")).map(str::to_string).collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn windows_paths_as_linux_sees_them() {
        assert_eq!(wsl_path(r"\\wsl.localhost\Ubuntu-main\home\me\talk"), Some((Some("Ubuntu-main".into()), "/home/me/talk".into())));
        assert_eq!(wsl_path(r"\\?\UNC\wsl.localhost\Ubuntu\home\me\talk\"), Some((Some("Ubuntu".into()), "/home/me/talk".into())));
        assert_eq!(wsl_path(r"\\wsl$\Ubuntu"), Some((Some("Ubuntu".into()), "/".into())));
        assert_eq!(wsl_path(r"C:\Talks\a b"), Some((None, "/mnt/c/Talks/a b".into())));
        assert_eq!(wsl_path(r"\\?\D:\x"), Some((None, "/mnt/d/x".into())));
        assert_eq!(wsl_path(r"\\server\share\x"), None);
    }

    #[test]
    fn pdf_beside_the_deck() {
        assert_eq!(pdf_path(Path::new("/d/talk.slideBlaster.md")), PathBuf::from("/d/talk.pdf"));
        assert_eq!(pdf_path(Path::new("/d/arch.tikz")), PathBuf::from("/d/arch.pdf"));
        assert_eq!(plain_path(Path::new(r"\\?\UNC\wsl.localhost\Ubuntu\home\me\talk.pdf")), r"\\wsl.localhost\Ubuntu\home\me\talk.pdf");
        assert_eq!(plain_path(Path::new(r"\\?\C:\Talks\a.pdf")), r"C:\Talks\a.pdf");
        assert_eq!(plain_path(Path::new("/d/talk.pdf")), "/d/talk.pdf");
    }
}
