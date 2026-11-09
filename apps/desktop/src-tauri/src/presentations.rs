//! The list of known presentations (project folders) and the small pure helpers around it.
//! Persisted as JSON in the app config dir: `[{ "path", "title"?, "lastOpened" }]`.
//! Nothing here touches Tauri, so it is unit-tested directly.

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Presentation {
    pub path: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    /// Unix milliseconds.
    #[serde(default)]
    pub last_opened: u64,
}

#[derive(Default)]
pub struct Store {
    file: PathBuf,
    items: Vec<Presentation>,
}

pub fn now_ms() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
}

impl Store {
    pub fn load(file: PathBuf) -> Store {
        let items = std::fs::read_to_string(&file).ok().and_then(|s| serde_json::from_str(&s).ok()).unwrap_or_default();
        Store { file, items }
    }

    fn save(&self) {
        if let Some(dir) = self.file.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        if let Ok(json) = serde_json::to_string_pretty(&self.items) {
            let tmp = self.file.with_extension("json.tmp");
            if std::fs::write(&tmp, json).is_ok() {
                let _ = std::fs::rename(&tmp, &self.file);
            }
        }
    }

    /// Most recently opened first.
    pub fn list(&self) -> Vec<Presentation> {
        let mut items = self.items.clone();
        items.sort_by(|a, b| b.last_opened.cmp(&a.last_opened).then_with(|| a.path.cmp(&b.path)));
        items
    }

    /// Most recently opened folder that still exists.
    pub fn most_recent(&self) -> Option<PathBuf> {
        self.list().into_iter().map(|p| PathBuf::from(p.path)).find(|p| p.is_dir())
    }

    /// Add `folder`, or bump it to "just opened".
    pub fn touch(&mut self, folder: &Path, now: u64) {
        let path = folder.to_string_lossy().into_owned();
        let title = folder_title(folder);
        match self.items.iter_mut().find(|p| p.path == path) {
            Some(p) => {
                p.last_opened = now;
                if title.is_some() {
                    p.title = title;
                }
            }
            None => self.items.push(Presentation { path, title, last_opened: now }),
        }
        self.save();
    }

    pub fn remove(&mut self, path: &str) {
        self.items.retain(|p| p.path != path);
        self.save();
    }
}

/// The name shown for a presentation: its deck title, else the folder name.
pub fn display_name(p: &Presentation) -> String {
    match p.title.as_deref().map(str::trim).filter(|t| !t.is_empty()) {
        Some(t) => t.to_string(),
        None => Path::new(&p.path).file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_else(|| p.path.clone()),
    }
}

/// `title:` from a leading `---` frontmatter block (plain or quoted scalar), if any.
pub fn frontmatter_title(text: &str) -> Option<String> {
    let mut lines = text.lines();
    if lines.next()?.trim_end() != "---" {
        return None;
    }
    for line in lines {
        let line = line.trim_end();
        if line == "---" || line == "..." {
            return None;
        }
        if let Some(rest) = line.strip_prefix("title:") {
            let v = rest.trim();
            let v = match (v.chars().next(), v.chars().last()) {
                (Some(a @ ('"' | '\'')), Some(b)) if a == b && v.len() >= 2 => &v[1..v.len() - 1],
                _ => v,
            };
            return if v.is_empty() { None } else { Some(v.to_string()) };
        }
    }
    None
}

/// Title of the first `*.slideBlaster.md` in `folder` (sorted by name), reading only its head.
pub fn folder_title(folder: &Path) -> Option<String> {
    use std::io::Read;
    let mut decks: Vec<PathBuf> = std::fs::read_dir(folder)
        .ok()?
        .filter_map(Result::ok)
        .map(|e| e.path())
        .filter(|p| p.file_name().is_some_and(|n| n.to_string_lossy().ends_with(".slideBlaster.md")))
        .collect();
    decks.sort();
    let mut buf = vec![0u8; 4096];
    let n = std::fs::File::open(decks.first()?).ok()?.read(&mut buf).ok()?;
    frontmatter_title(&String::from_utf8_lossy(&buf[..n]))
}

/// A sub-presentation: a deck some presentation includes with `\include{path}`.
/// Always derived from the including deck's text, never stored.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SubPresentation {
    /// The folder that opens it.
    pub path: String,
    pub title: String,
    pub current: bool,
    pub children: Vec<SubPresentation>,
}

/// The paths of the `\include[..]{path}` lines of a deck's text, outside fenced code.
pub fn include_paths(text: &str) -> Vec<String> {
    let mut fence: Option<(char, usize)> = None;
    let mut out = Vec::new();
    for line in text.lines() {
        let stripped = line.trim_start_matches(' ');
        let indent = line.len() - stripped.len();
        match fence {
            Some((c, n)) => {
                let run = stripped.chars().take_while(|&x| x == c).count();
                if indent <= 3 && run >= n && stripped[run..].trim().is_empty() {
                    fence = None;
                }
                continue;
            }
            None => {
                if let Some(c) = stripped.chars().next().filter(|c| (*c == '`' || *c == '~') && indent <= 3) {
                    let run = stripped.chars().take_while(|&x| x == c).count();
                    if run >= 3 && !(c == '`' && stripped[run..].contains('`')) {
                        fence = Some((c, run));
                        continue;
                    }
                }
            }
        }
        let Some(rest) = line.strip_prefix("\\include") else { continue };
        let rest = match rest.strip_prefix('[') {
            Some(r) => match r.split_once(']') {
                Some((_, after)) => after,
                None => continue,
            },
            None => rest,
        };
        let Some(rest) = rest.strip_prefix('{') else { continue };
        let Some((path, tail)) = rest.split_once('}') else { continue };
        let path = path.trim();
        if tail.trim().is_empty() && !path.is_empty() {
            out.push(path.to_string());
        }
    }
    out
}

/// The first `*.slideBlaster.md` in `folder` (sorted by name).
pub fn deck_file(folder: &Path) -> Option<PathBuf> {
    let mut decks: Vec<PathBuf> = std::fs::read_dir(folder)
        .ok()?
        .filter_map(Result::ok)
        .map(|e| e.path())
        .filter(|p| p.file_name().is_some_and(|n| n.to_string_lossy().ends_with(".slideBlaster.md")))
        .collect();
    decks.sort();
    decks.into_iter().next()
}

/// The decks included by the deck in `folder`, nested recursively (cycles and missing paths are
/// skipped). `path` is a folder (an included file opens its folder); relative to `folder` as written.
pub fn sub_presentations(folder: &Path, current: Option<&str>) -> Vec<SubPresentation> {
    fn go(folder: &Path, current: Option<&str>, seen: &mut Vec<PathBuf>, out: &mut Vec<SubPresentation>) {
        if seen.len() > 8 {
            return;
        }
        let Some(deck) = deck_file(folder) else { return };
        let Ok(text) = std::fs::read_to_string(&deck) else { return };
        for rel in include_paths(&text) {
            let target = folder.join(&rel);
            let (sub_folder, sub_deck) = if target.is_dir() {
                match deck_file(&target) {
                    Some(d) => (target.clone(), d),
                    None => continue,
                }
            } else if target.is_file() && target.file_name().is_some_and(|n| n.to_string_lossy().ends_with(".slideBlaster.md")) {
                (target.parent().map(Path::to_path_buf).unwrap_or_default(), target.clone())
            } else {
                continue;
            };
            let Ok(sub_folder) = sub_folder.canonicalize() else { continue };
            if seen.contains(&sub_folder) {
                continue;
            }
            seen.push(sub_folder.clone());
            let title = std::fs::File::open(&sub_deck)
                .ok()
                .and_then(|mut f| {
                    use std::io::Read;
                    let mut buf = vec![0u8; 4096];
                    let n = f.read(&mut buf).ok()?;
                    frontmatter_title(&String::from_utf8_lossy(&buf[..n]))
                })
                .or_else(|| sub_folder.file_name().map(|n| n.to_string_lossy().into_owned()))
                .unwrap_or_default();
            let path = sub_folder.to_string_lossy().into_owned();
            let mut children = Vec::new();
            go(&sub_folder, current, seen, &mut children);
            seen.pop();
            out.push(SubPresentation { current: current == Some(path.as_str()), path, title, children });
        }
    }
    let mut out = Vec::new();
    let mut seen = vec![folder.canonicalize().unwrap_or_else(|_| folder.to_path_buf())];
    go(folder, current, &mut seen, &mut out);
    out
}

fn contains_path(subs: &[SubPresentation], folder: &str) -> bool {
    subs.iter().any(|s| s.path == folder || contains_path(&s.children, folder))
}

impl Store {
    pub fn contains(&self, folder: &Path) -> bool {
        let path = folder.to_string_lossy();
        self.items.iter().any(|p| p.path == path)
    }

    /// Whether `folder` is, at any depth, a sub-presentation of a listed presentation.
    pub fn is_nested(&self, folder: &Path) -> bool {
        let Ok(folder) = folder.canonicalize() else { return false };
        let folder = folder.to_string_lossy().into_owned();
        self.items.iter().any(|p| p.path != folder && contains_path(&sub_presentations(Path::new(&p.path), None), &folder))
    }
}

#[derive(Debug, Default, PartialEq)]
pub struct Args {
    pub folder: Option<PathBuf>,
    pub background: bool,
}

/// Command-line arguments (without argv[0]): `--background` and an optional folder.
/// A relative folder is resolved against `cwd`; a non-directory is ignored.
pub fn parse_args<I: IntoIterator<Item = String>>(args: I, cwd: &Path) -> Args {
    let mut out = Args::default();
    for a in args {
        if a == "--background" {
            out.background = true;
        } else if !a.starts_with("--") && out.folder.is_none() {
            let p = cwd.join(&a); // absolute `a` replaces cwd
            if p.is_dir() {
                out.folder = Some(p.canonicalize().unwrap_or(p));
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp(name: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("sb-pres-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn frontmatter() {
        assert_eq!(frontmatter_title("---\ntitle: Hello World\ntheme: x\n---\n# a"), Some("Hello World".into()));
        assert_eq!(frontmatter_title("---\ntitle: \"Quoted: yes\"\n---\n"), Some("Quoted: yes".into()));
        assert_eq!(frontmatter_title("---\ntheme: x\n---\ntitle: nope"), None);
        assert_eq!(frontmatter_title("# no frontmatter\ntitle: x"), None);
        assert_eq!(frontmatter_title("---\ntitle:\n---\n"), None);
    }

    #[test]
    fn names() {
        let p = |path: &str, title: Option<&str>| Presentation { path: path.into(), title: title.map(Into::into), last_opened: 0 };
        assert_eq!(display_name(&p("/a/b/talk", Some("My Talk"))), "My Talk");
        assert_eq!(display_name(&p("/a/b/talk", None)), "talk");
        assert_eq!(display_name(&p("/a/b/talk", Some("  "))), "talk");
    }

    #[test]
    fn store_roundtrip_order_remove() {
        let dir = tmp("store");
        let (a, b) = (dir.join("a"), dir.join("b"));
        std::fs::create_dir_all(&a).unwrap();
        std::fs::create_dir_all(&b).unwrap();
        std::fs::write(a.join("x.slideBlaster.md"), "---\ntitle: Alpha\n---\n").unwrap();
        let file = dir.join("cfg/presentations.json");
        let mut s = Store::load(file.clone());
        assert!(s.most_recent().is_none());
        s.touch(&a, 10);
        s.touch(&b, 20);
        s.touch(&a, 30);
        let again = Store::load(file);
        let l = again.list();
        assert_eq!(l.len(), 2);
        assert_eq!(l[0].path, a.to_string_lossy());
        assert_eq!(l[0].title.as_deref(), Some("Alpha"));
        assert_eq!(again.most_recent(), Some(a.clone()));
        let mut again = again;
        again.remove(&a.to_string_lossy());
        assert_eq!(again.most_recent(), Some(b));
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn most_recent_skips_missing_folders() {
        let dir = tmp("missing");
        let mut s = Store::load(dir.join("p.json"));
        let real = dir.join("real");
        std::fs::create_dir_all(&real).unwrap();
        s.touch(&real, 1);
        s.touch(&dir.join("gone"), 2);
        assert_eq!(s.most_recent(), Some(real));
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn include_lines() {
        let text = "---\ntitle: x\n---\n# S {#s}\n\\include{../a}\n\\include[titleslide, dividers]{b/c.slideBlaster.md}  \n```\n\\include{no}\n```\n\\includegraphics{x}\n  \\include{indented}\n\\include{}\n";
        assert_eq!(include_paths(text), vec!["../a".to_string(), "b/c.slideBlaster.md".to_string()]);
    }

    #[test]
    fn sub_presentations_nest_and_resolve() {
        let dir = tmp("subs").canonicalize().unwrap();
        let write = |p: &str, body: &str| {
            let f = dir.join(p);
            std::fs::create_dir_all(f.parent().unwrap()).unwrap();
            std::fs::write(f, body).unwrap();
        };
        write("parent/talk.slideBlaster.md", "---\ntitle: Parent\n---\n# A {#a}\n\\include{../kid}\n\\include{../missing}\n\\include{../loop}\n");
        write("kid/kid.slideBlaster.md", "---\ntitle: Kid\n---\n\\include{grand/g.slideBlaster.md}\n");
        write("kid/grand/g.slideBlaster.md", "---\ntitle: Grand\n---\n## g\n");
        write("loop/l.slideBlaster.md", "---\ntitle: Loop\n---\n\\include{../parent}\n");
        let kid = dir.join("kid").to_string_lossy().into_owned();
        let subs = sub_presentations(&dir.join("parent"), Some(&kid));
        assert_eq!(subs.iter().map(|s| s.title.as_str()).collect::<Vec<_>>(), vec!["Kid", "Loop"]);
        assert!(subs[0].current && !subs[1].current);
        assert_eq!(subs[0].children.len(), 1);
        assert_eq!(subs[0].children[0].title, "Grand");
        assert_eq!(subs[0].children[0].path, dir.join("kid/grand").to_string_lossy());
        assert!(subs[1].children.is_empty(), "a cycle back to the parent is cut");
        let mut store = Store::load(dir.join("cfg.json"));
        store.touch(&dir.join("parent"), 1);
        assert!(store.is_nested(&dir.join("kid/grand")));
        assert!(!store.is_nested(&dir.join("parent")));
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn args() {
        let dir = tmp("args");
        let sub = dir.join("deck");
        std::fs::create_dir_all(&sub).unwrap();
        let a = parse_args(["--background".to_string(), "deck".to_string()], &dir);
        assert!(a.background);
        assert_eq!(a.folder, Some(sub.canonicalize().unwrap()));
        assert_eq!(parse_args(["nope".to_string()], &dir), Args::default());
        assert_eq!(parse_args(Vec::new(), &dir), Args::default());
        let _ = std::fs::remove_dir_all(dir);
    }
}
