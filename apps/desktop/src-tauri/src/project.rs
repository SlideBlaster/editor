//! The project folder as the in-page core sees it: which files it holds, reading, conditional
//! writing, and what changed since the last look. The rules mirror `sb serve`
//! (`SlideBlaster.Cli.Watch.scanProject`, `SlideBlaster.Cli.Cap`), so a deck reads the same files
//! whether the core runs in the page or in the server.
//!
//! A file is named by a key: its path relative to the project folder with `/` separators. Files of
//! included decks outside the folder spell each leading `..` as `_up`.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

use crate::presentations::include_paths;

const DECK_SUFFIX: &str = ".slideBlaster.md";
/// Larger files are never handed to the core.
const LARGEST_FILE: u64 = 16 * 1024 * 1024;
pub const NODE_SIZES: &str = ".slideblaster/cache/node-sizes.json";

/// Modification time and size: enough to notice a change.
pub type Stamp = (Option<SystemTime>, u64);

#[derive(Clone, Debug, PartialEq)]
pub struct Entry {
    pub real: PathBuf,
    pub stamp: Stamp,
}

pub type Scan = BTreeMap<String, Entry>;

fn skipped(name: &str) -> bool {
    matches!(name, ".slideblaster" | ".git" | "node_modules")
}

fn stamp_of(path: &Path) -> Option<Stamp> {
    let meta = std::fs::metadata(path).ok()?;
    meta.is_file().then(|| (meta.modified().ok(), meta.len()))
}

/// Every regular file under `root`, keyed relative to it. Symbolic links to folders are not followed.
fn scan_tree(root: &Path) -> BTreeMap<String, Stamp> {
    fn go(root: &Path, relative: &str, out: &mut BTreeMap<String, Stamp>) {
        let dir = if relative.is_empty() { root.to_path_buf() } else { root.join(relative) };
        let Ok(listing) = std::fs::read_dir(&dir) else { return };
        for entry in listing.filter_map(Result::ok) {
            let name = entry.file_name().to_string_lossy().into_owned();
            if skipped(&name) {
                continue;
            }
            let rel = if relative.is_empty() { name } else { format!("{relative}/{name}") };
            let full = root.join(&rel);
            let link = std::fs::symlink_metadata(&full).map(|m| m.file_type().is_symlink()).unwrap_or(false);
            if full.is_dir() && !link {
                go(root, &rel, out);
            } else if let Some(stamp) = stamp_of(&full) {
                out.insert(rel, stamp);
            }
        }
    }
    let mut out = BTreeMap::new();
    go(root, "", &mut out);
    out
}

/// `a/./b/../c` as `a/c`; a `..` that leaves the root becomes `_up`.
pub fn normalize_key(key: &str) -> String {
    let mut acc: Vec<&str> = Vec::new();
    for segment in key.split('/') {
        match segment {
            "" | "." => {}
            ".." => match acc.last() {
                Some(top) if *top != "_up" => {
                    acc.pop();
                }
                _ => acc.push("_up"),
            },
            other => acc.push(other),
        }
    }
    acc.join("/")
}

/// The folder part of a key (empty at the root).
fn key_directory(key: &str) -> &str {
    key.rsplit_once('/').map(|(dir, _)| dir).unwrap_or("")
}

/// The key as a path relative to the root folder (`_up` back to `..`).
fn key_to_relative(key: &str) -> PathBuf {
    key.split('/').map(|s| if s == "_up" { ".." } else { s }).collect()
}

/// The project tree plus the files of every deck it includes (`\include{..}`), transitively. An
/// included folder contributes its whole tree; an included file its folder (just the file when
/// that folder is an ancestor of the root).
pub fn scan(root: &Path) -> Scan {
    fn tree(key: &str, real_dir: &Path) -> Scan {
        scan_tree(real_dir)
            .into_iter()
            .map(|(rel, stamp)| {
                let real = real_dir.join(&rel);
                (if key.is_empty() { rel } else { format!("{key}/{rel}") }, Entry { real, stamp })
            })
            .collect()
    }
    fn visit(root: &Path, acc: &mut Scan, seen: &mut Vec<String>, deck_key: &str) {
        if seen.iter().any(|s| s == deck_key) {
            return;
        }
        seen.push(deck_key.to_string());
        let Some(entry) = acc.get(deck_key) else { return };
        let text = String::from_utf8_lossy(&std::fs::read(&entry.real).unwrap_or_default()).into_owned();
        for path in include_paths(&text) {
            let target = normalize_key(&format!("{}/{}", key_directory(deck_key), path));
            let real = root.join(key_to_relative(&target));
            let file_dir = key_directory(&target).to_string();
            let ancestor_only = file_dir.split('/').filter(|s| !s.is_empty()).all(|s| s == "_up");
            let added: Scan = if real.is_dir() {
                tree(&target, &real)
            } else if target.ends_with(DECK_SUFFIX) {
                if ancestor_only {
                    stamp_of(&real).map(|stamp| Scan::from([(target.clone(), Entry { real: real.clone(), stamp })])).unwrap_or_default()
                } else {
                    tree(&file_dir, real.parent().unwrap_or(root))
                }
            } else {
                Scan::new()
            };
            let decks: Vec<String> =
                added.keys().filter(|k| k.ends_with(DECK_SUFFIX) && (key_directory(k) == target || **k == target)).cloned().collect();
            for (key, entry) in added {
                acc.entry(key).or_insert(entry);
            }
            for deck in decks {
                visit(root, acc, seen, &deck);
            }
        }
    }
    let mut acc: Scan = scan_tree(root).into_iter().map(|(rel, stamp)| (rel.clone(), Entry { real: root.join(&rel), stamp })).collect();
    let decks: Vec<String> = acc.keys().filter(|k| k.ends_with(DECK_SUFFIX)).cloned().collect();
    let mut seen = Vec::new();
    for deck in decks {
        visit(root, &mut acc, &mut seen, &deck);
    }
    acc
}

/// The keys that were created, changed or deleted between two scans, sorted.
pub fn changed(old: &Scan, new: &Scan) -> Vec<String> {
    let mut out: Vec<String> = new.iter().filter(|(k, e)| old.get(*k).map(|o| o.stamp != e.stamp).unwrap_or(true)).map(|(k, _)| k.clone()).collect();
    out.extend(old.keys().filter(|k| !new.contains_key(*k)).cloned());
    out.sort();
    out
}

// --- one byte string for several: [count] then, per part, [length][bytes]; lengths are u32 LE ----

pub fn pack_parts(parts: &[&[u8]]) -> Vec<u8> {
    let mut out = Vec::with_capacity(4 + parts.iter().map(|p| 4 + p.len()).sum::<usize>());
    out.extend_from_slice(&(parts.len() as u32).to_le_bytes());
    for part in parts {
        out.extend_from_slice(&(part.len() as u32).to_le_bytes());
        out.extend_from_slice(part);
    }
    out
}

pub fn unpack_parts(packed: &[u8]) -> Option<Vec<&[u8]>> {
    let word = |at: usize| packed.get(at..at + 4).map(|b| u32::from_le_bytes([b[0], b[1], b[2], b[3]]) as usize);
    let count = word(0)?;
    let mut parts = Vec::new();
    let mut at = 4;
    for _ in 0..count {
        let length = word(at)?;
        at += 4;
        parts.push(packed.get(at..at.checked_add(length)?)?);
        at += length;
    }
    Some(parts)
}

/// Every file the core may read, as `[key, bytes, key, bytes, ...]` parts: the scan (without huge
/// files) plus the measured node sizes, the one cache file the core lays pictures out from.
pub fn list_packed(root: &Path) -> Vec<u8> {
    let mut files: Vec<(String, Vec<u8>)> = scan(root)
        .into_iter()
        .filter(|(_, entry)| entry.stamp.1 <= LARGEST_FILE)
        .filter_map(|(key, entry)| std::fs::read(&entry.real).ok().map(|bytes| (key, bytes)))
        .collect();
    if let Ok(bytes) = std::fs::read(root.join(NODE_SIZES)) {
        files.push((NODE_SIZES.to_string(), bytes));
    }
    let parts: Vec<&[u8]> = files.iter().flat_map(|(key, bytes)| [key.as_bytes(), bytes.as_slice()]).collect();
    pack_parts(&parts)
}

fn segments_of(key: &str) -> Option<Vec<&str>> {
    if key.is_empty() || key.starts_with('/') || key.contains('\\') || key.contains('\0') {
        return None;
    }
    let segments: Vec<&str> = key.split('/').collect();
    (!segments.iter().any(|s| s.is_empty() || *s == "." || *s == "..")).then_some(segments)
}

/// One file by key (`_up` segments reach included decks beside the project), or `None`.
pub fn read(root: &Path, key: &str) -> Option<Vec<u8>> {
    let segments = segments_of(key)?;
    let up = segments.iter().take_while(|s| **s == "_up").count();
    if segments[up..].iter().any(|s| *s == "_up") {
        return None;
    }
    let path = root.join(key_to_relative(key));
    path.is_file().then(|| std::fs::read(path).ok()).flatten()
}

/// A path inside the project folder that may be written: never outside it, never git's or the cache.
fn writable(root: &Path, key: &str) -> Result<PathBuf, String> {
    let segments = segments_of(key).ok_or("path is not allowed")?;
    if segments.iter().any(|s| *s == "_up") || segments[0] == ".git" || (segments[0] == ".slideblaster" && segments.get(1) == Some(&"cache")) {
        return Err("path is not allowed".into());
    }
    let target = segments.iter().fold(root.to_path_buf(), |p, s| p.join(s));
    // A link on the way must not lead out of the project.
    let real_root = root.canonicalize().map_err(|e| e.to_string())?;
    let mut probe = target.clone();
    while !probe.exists() {
        match probe.parent() {
            Some(parent) => probe = parent.to_path_buf(),
            None => return Err("path is not allowed".into()),
        }
    }
    let real = probe.canonicalize().map_err(|e| e.to_string())?;
    if !real.starts_with(&real_root) {
        return Err("path is not allowed".into());
    }
    Ok(target)
}

fn replace(target: &Path, bytes: &[u8]) -> Result<(), String> {
    if let Some(parent) = target.parent() {
        std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }
    let name = target.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    let sibling = target.with_file_name(format!(".{name}.sb-{}.tmp", std::process::id()));
    std::fs::write(&sibling, bytes).map_err(|e| e.to_string())?;
    if let Ok(meta) = std::fs::metadata(target) {
        let _ = std::fs::set_permissions(&sibling, meta.permissions());
    }
    std::fs::rename(&sibling, target).map_err(|e| {
        let _ = std::fs::remove_file(&sibling);
        e.to_string()
    })
}

/// Replace a project file only if it still holds `expected` (`None`: it must not exist yet).
/// The check and the replacement are not one atomic step: another writer can slip in between.
pub fn write(root: &Path, key: &str, expected: Option<&[u8]>, bytes: &[u8]) -> Result<(), String> {
    let target = writable(root, key)?;
    let current = std::fs::read(&target).ok();
    if current.as_deref() != expected {
        return Err("conflict".into());
    }
    replace(&target, bytes)
}

/// Keep a derived file inside the project's cache folder.
pub fn write_cache(root: &Path, key: &str, bytes: &[u8]) -> Result<(), String> {
    let segments = segments_of(key).ok_or("path is not allowed")?;
    if segments.len() < 3 || segments[0] != ".slideblaster" || segments[1] != "cache" || segments.iter().any(|s| *s == "_up") {
        return Err("path is not allowed".into());
    }
    replace(&segments.iter().fold(root.to_path_buf(), |p, s| p.join(s)), bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("sb-project-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn keys() {
        assert_eq!(normalize_key("a/./b/../c"), "a/c");
        assert_eq!(normalize_key("/../x/talk.slideBlaster.md"), "_up/x/talk.slideBlaster.md");
        assert_eq!(normalize_key("_up/a/../../b"), "_up/_up/b");
        assert_eq!(key_to_relative("_up/x/y"), PathBuf::from("../x/y"));
    }

    #[test]
    fn parts_roundtrip() {
        let packed = pack_parts(&[b"ab", b"", b"xyz"]);
        assert_eq!(unpack_parts(&packed), Some(vec![&b"ab"[..], &b""[..], &b"xyz"[..]]));
        assert_eq!(unpack_parts(&packed[..packed.len() - 1]), None);
        assert_eq!(unpack_parts(&pack_parts(&[])), Some(vec![]));
    }

    #[test]
    fn scan_follows_includes_and_skips_caches() {
        let base = tmp("scan");
        let (main, other) = (base.join("main"), base.join("other"));
        std::fs::create_dir_all(main.join(".slideblaster/cache")).unwrap();
        std::fs::create_dir_all(main.join("figures")).unwrap();
        std::fs::create_dir_all(&other).unwrap();
        std::fs::write(main.join("talk.slideBlaster.md"), "## A\n\n\\include{../other}\n").unwrap();
        std::fs::write(main.join("figures/a.svg"), "<svg/>").unwrap();
        std::fs::write(main.join(".slideblaster/cache/x.json"), "{}").unwrap();
        std::fs::write(other.join("talk.slideBlaster.md"), "## B\n").unwrap();
        std::fs::write(other.join("pic.png"), "png").unwrap();
        let found = scan(&main);
        let keys: Vec<&str> = found.keys().map(String::as_str).collect();
        assert_eq!(keys, vec!["_up/other/pic.png", "_up/other/talk.slideBlaster.md", "figures/a.svg", "talk.slideBlaster.md"]);
        assert_eq!(read(&main, "_up/other/pic.png"), Some(b"png".to_vec()));
        assert_eq!(read(&main, "figures/../talk.slideBlaster.md"), None);
        let before = found.clone();
        std::fs::write(other.join("pic.png"), "larger png").unwrap();
        std::fs::remove_file(main.join("figures/a.svg")).unwrap();
        assert_eq!(changed(&before, &scan(&main)), vec!["_up/other/pic.png", "figures/a.svg"]);
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn writes_are_conditional_and_stay_inside() {
        let root = tmp("write");
        assert_eq!(write(&root, "deck.slideBlaster.md", None, b"one"), Ok(()));
        assert_eq!(write(&root, "deck.slideBlaster.md", None, b"two"), Err("conflict".into()));
        assert_eq!(write(&root, "deck.slideBlaster.md", Some(b"stale"), b"two"), Err("conflict".into()));
        assert_eq!(write(&root, "deck.slideBlaster.md", Some(b"one"), b"two"), Ok(()));
        assert_eq!(std::fs::read(root.join("deck.slideBlaster.md")).unwrap(), b"two");
        for bad in ["../x", "_up/x", "/abs", ".git/config", ".slideblaster/cache/a", "a//b", ""] {
            assert_eq!(write(&root, bad, None, b"x"), Err("path is not allowed".into()), "{bad}");
        }
        assert_eq!(write_cache(&root, NODE_SIZES, b"{}"), Ok(()));
        assert_eq!(write_cache(&root, "deck.slideBlaster.md", b"{}"), Err("path is not allowed".into()));
        assert!(String::from_utf8_lossy(&list_packed(&root)).contains("node-sizes.json"));
        let _ = std::fs::remove_dir_all(&root);
    }
}
