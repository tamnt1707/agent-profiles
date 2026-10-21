//! Profiles on disk, launcher scripts, and per-profile Claude config folders.
//!
//! Layout (everything under ~/.claude-profiles, nothing touches ~/.claude):
//!   profiles.json            profile list + app settings (no secrets)
//!   bin/claude-<slug>        launcher script per profile
//!   homes/<slug>/            CLAUDE_CONFIG_DIR for that profile

use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};

use crate::secret;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize, Default)]
pub enum AuthKind {
    /// ANTHROPIC_AUTH_TOKEN → `Authorization: Bearer …`
    #[default]
    Bearer,
    /// ANTHROPIC_API_KEY → `x-api-key: …`
    ApiKey,
    /// No credential (e.g. a local proxy)
    None,
}

impl AuthKind {
    pub const ALL: [AuthKind; 3] = [AuthKind::Bearer, AuthKind::ApiKey, AuthKind::None];
    pub fn label(self) -> &'static str {
        match self {
            AuthKind::Bearer => "Bearer token (ANTHROPIC_AUTH_TOKEN)",
            AuthKind::ApiKey => "API key (ANTHROPIC_API_KEY)",
            AuthKind::None => "Không cần key",
        }
    }
    fn env_var(self) -> Option<&'static str> {
        match self {
            AuthKind::Bearer => Some("ANTHROPIC_AUTH_TOKEN"),
            AuthKind::ApiKey => Some("ANTHROPIC_API_KEY"),
            AuthKind::None => None,
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, Default, PartialEq)]
#[serde(default)]
pub struct Profile {
    pub name: String,
    pub slug: String,
    pub base_url: String,
    pub auth: AuthKind,
    pub model: String,
    pub opus_model: String,
    pub sonnet_model: String,
    pub haiku_model: String,
    /// Extra `KEY=VALUE` lines.
    pub extra_env: String,
    pub workdir: String,
    /// Give this profile its own CLAUDE_CONFIG_DIR (recommended).
    pub isolate: bool,
    /// When isolated, symlink CLAUDE.md / skills / commands / agents from ~/.claude.
    pub share_from_default: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize, Default)]
pub enum TerminalApp {
    #[default]
    Terminal,
    ITerm,
}

impl TerminalApp {
    pub const ALL: [TerminalApp; 2] = [TerminalApp::Terminal, TerminalApp::ITerm];
    pub fn label(self) -> &'static str {
        match self {
            TerminalApp::Terminal => "Terminal",
            TerminalApp::ITerm => "iTerm2",
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, Default)]
#[serde(default)]
pub struct Data {
    pub terminal: TerminalApp,
    pub profiles: Vec<Profile>,
}

pub fn root() -> PathBuf {
    dirs::home_dir().unwrap_or_else(|| PathBuf::from(".")).join(".claude-profiles")
}
pub fn bin_dir() -> PathBuf {
    root().join("bin")
}
pub fn home_for(slug: &str) -> PathBuf {
    root().join("homes").join(slug)
}
pub fn script_for(slug: &str) -> PathBuf {
    bin_dir().join(format!("claude-{slug}"))
}
fn data_file() -> PathBuf {
    root().join("profiles.json")
}

pub fn load() -> Data {
    fs::read_to_string(data_file())
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default()
}

pub fn save(data: &Data) -> Result<()> {
    fs::create_dir_all(root())?;
    let tmp = data_file().with_extension("json.tmp");
    fs::write(&tmp, serde_json::to_string_pretty(data)?)?;
    fs::rename(tmp, data_file())?;
    Ok(())
}

pub fn slugify(name: &str) -> String {
    let mut out = String::new();
    for c in name.trim().to_lowercase().chars() {
        let c = fold_vietnamese(c);
        if c.is_ascii_alphanumeric() {
            out.push(c);
        } else if !out.ends_with('-') && !out.is_empty() {
            out.push('-');
        }
    }
    out.trim_end_matches('-').to_string()
}

fn fold_vietnamese(c: char) -> char {
    const MAP: &[(&str, char)] = &[
        ("àáạảãâầấậẩẫăằắặẳẵ", 'a'),
        ("èéẹẻẽêềếệểễ", 'e'),
        ("ìíịỉĩ", 'i'),
        ("òóọỏõôồốộổỗơờớợởỡ", 'o'),
        ("ùúụủũưừứựửữ", 'u'),
        ("ỳýỵỷỹ", 'y'),
        ("đ", 'd'),
    ];
    MAP.iter().find(|(s, _)| s.contains(c)).map(|(_, r)| *r).unwrap_or(c)
}

/// Single-quote a string for zsh/bash.
pub fn sh_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', r"'\''"))
}

fn valid_env_name(k: &str) -> bool {
    let mut chars = k.chars();
    matches!(chars.next(), Some(c) if c.is_ascii_alphabetic() || c == '_')
        && chars.all(|c| c.is_ascii_alphanumeric() || c == '_')
}

pub fn parse_extra_env(text: &str) -> Result<Vec<(String, String)>> {
    let mut out = Vec::new();
    for (i, line) in text.lines().enumerate() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let line = line.strip_prefix("export ").unwrap_or(line);
        let Some((k, v)) = line.split_once('=') else {
            bail!("Dòng {} của biến môi trường thiếu dấu '=': {line}", i + 1);
        };
        let k = k.trim();
        if !valid_env_name(k) {
            bail!("Tên biến không hợp lệ ở dòng {}: {k}", i + 1);
        }
        let v = v.trim().trim_matches('"').trim_matches('\'');
        out.push((k.to_string(), v.to_string()));
    }
    Ok(out)
}

pub fn validate(p: &Profile, others: &[Profile]) -> Result<()> {
    if p.name.trim().is_empty() {
        bail!("Profile cần có tên");
    }
    if p.slug.is_empty() {
        bail!("Tên profile cần có ít nhất một chữ cái hoặc số");
    }
    if others.iter().any(|o| o.slug == p.slug) {
        bail!("Đã có profile khác dùng lệnh claude-{}", p.slug);
    }
    let url = p.base_url.trim();
    if !url.is_empty() && !(url.starts_with("https://") || url.starts_with("http://")) {
        bail!("Base URL phải bắt đầu bằng https:// hoặc http://");
    }
    parse_extra_env(&p.extra_env)?;
    Ok(())
}

/// The launcher. It holds no secret: the key is fetched from Keychain when it runs.
pub fn render_script(p: &Profile) -> Result<String> {
    let mut s = String::new();
    s.push_str("#!/bin/zsh\n");
    s.push_str(&format!(
        "# Tạo bởi Claude Profiles cho profile \"{}\". File này được ghi đè mỗi lần lưu.\n\n",
        p.name.replace('\n', " ")
    ));
    s.push_str(
        "# Bỏ cấu hình nhà cung cấp còn sót trong shell để profile không bị lẫn\n\
         unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL ANTHROPIC_MODEL \\\n  \
         ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL \\\n  \
         ANTHROPIC_SMALL_FAST_MODEL\n\n",
    );

    if let Some(var) = p.auth.env_var() {
        s.push_str(&format!(
            "__k=\"$(/usr/bin/security find-generic-password -s {} -a {} -w 2>/dev/null)\"\n",
            sh_quote(secret::SERVICE),
            sh_quote(&p.slug)
        ));
        s.push_str(&format!(
            "if [[ -z \"$__k\" ]]; then\n  echo \"Chưa có API key cho profile {} trong Keychain. Mở app Claude Profiles để nhập.\" >&2\n  exit 1\nfi\n",
            sh_quote(&p.name)
        ));
        s.push_str(&format!("export {var}=\"$__k\"\nunset __k\n\n"));
    }

    let mut export = |k: &str, v: &str| {
        if !v.trim().is_empty() {
            s.push_str(&format!("export {k}={}\n", sh_quote(v.trim())));
        }
    };
    export("ANTHROPIC_BASE_URL", &p.base_url);
    export("ANTHROPIC_MODEL", &p.model);
    export("ANTHROPIC_DEFAULT_OPUS_MODEL", &p.opus_model);
    export("ANTHROPIC_DEFAULT_SONNET_MODEL", &p.sonnet_model);
    export("ANTHROPIC_DEFAULT_HAIKU_MODEL", &p.haiku_model);
    if p.isolate {
        export("CLAUDE_CONFIG_DIR", &home_for(&p.slug).to_string_lossy());
    }
    for (k, v) in parse_extra_env(&p.extra_env)? {
        export(&k, &v);
    }

    s.push_str("\nexec claude \"$@\"\n");
    Ok(s)
}

/// Write the launcher, create the isolated config folder and shared links.
pub fn materialize(p: &Profile) -> Result<()> {
    fs::create_dir_all(bin_dir())?;
    let path = script_for(&p.slug);
    fs::write(&path, render_script(p)?).with_context(|| format!("Không ghi được {}", path.display()))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&path, fs::Permissions::from_mode(0o755))?;
    }
    if p.isolate {
        let home = home_for(&p.slug);
        fs::create_dir_all(&home)?;
        if p.share_from_default {
            link_shared(&home)?;
        }
    }
    Ok(())
}

/// Items shared read-through from ~/.claude. settings.json and credentials are
/// deliberately NOT shared, so each profile keeps its own provider settings.
const SHARED: &[&str] = &["CLAUDE.md", "skills", "commands", "agents", "output-styles"];

fn link_shared(home: &Path) -> Result<()> {
    let Some(src_root) = dirs::home_dir().map(|h| h.join(".claude")) else { return Ok(()) };
    for item in SHARED {
        let src = src_root.join(item);
        let dst = home.join(item);
        if src.exists() && fs::symlink_metadata(&dst).is_err() {
            #[cfg(unix)]
            std::os::unix::fs::symlink(&src, &dst)
                .with_context(|| format!("Không tạo được liên kết {}", dst.display()))?;
        }
    }
    Ok(())
}

/// Handle a rename: move the Keychain entry, launcher and config folder.
pub fn migrate_slug(old: &str, new: &str) -> Result<()> {
    if old == new || old.is_empty() {
        return Ok(());
    }
    if let Some(key) = secret::get(old)? {
        secret::set(new, &key)?;
        secret::delete(old)?;
    }
    let _ = fs::remove_file(script_for(old));
    let (oh, nh) = (home_for(old), home_for(new));
    if oh.exists() && !nh.exists() {
        fs::rename(oh, nh)?;
    }
    Ok(())
}

/// Remove a profile's launcher and key. The config folder (sessions, history) is kept.
pub fn remove(p: &Profile) -> Result<()> {
    let _ = fs::remove_file(script_for(&p.slug));
    secret::delete(&p.slug)
}

/// Open a new terminal window running the profile's launcher.
pub fn launch(p: &Profile, term: TerminalApp) -> Result<()> {
    let mut cmd = String::new();
    let dir = p.workdir.trim();
    if !dir.is_empty() {
        cmd.push_str(&format!("cd {} && ", sh_quote(dir)));
    }
    cmd.push_str(&sh_quote(&script_for(&p.slug).to_string_lossy()));
    let as_str = cmd.replace('\\', "\\\\").replace('"', "\\\"");

    let script = match term {
        TerminalApp::Terminal => format!(
            "tell application \"Terminal\"\n activate\n do script \"{as_str}\"\nend tell"
        ),
        TerminalApp::ITerm => format!(
            "tell application \"iTerm\"\n activate\n set w to (create window with default profile)\n tell current session of w to write text \"{as_str}\"\nend tell"
        ),
    };
    let status = std::process::Command::new("osascript")
        .arg("-e")
        .arg(script)
        .status()
        .context("Không chạy được osascript (chỉ có trên macOS)")?;
    if !status.success() {
        bail!("Không mở được {} (osascript lỗi)", term.label());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn slug_folds_vietnamese() {
        assert_eq!(slugify("GLM Đẹp Trai!"), "glm-dep-trai");
        assert_eq!(slugify("  Kimi K2  "), "kimi-k2");
    }

    #[test]
    fn quoting() {
        assert_eq!(sh_quote("it's"), r"'it'\''s'");
    }

    #[test]
    fn script_has_no_secret_and_exports() {
        let p = Profile {
            name: "Test".into(),
            slug: "test".into(),
            base_url: "https://example.com/anthropic".into(),
            auth: AuthKind::Bearer,
            model: "m-1".into(),
            extra_env: "API_TIMEOUT_MS=600000\n# comment".into(),
            isolate: true,
            ..Default::default()
        };
        let s = render_script(&p).unwrap();
        assert!(s.contains("export ANTHROPIC_AUTH_TOKEN=\"$__k\""));
        assert!(s.contains("export ANTHROPIC_BASE_URL='https://example.com/anthropic'"));
        assert!(s.contains("export ANTHROPIC_MODEL='m-1'"));
        assert!(s.contains("export API_TIMEOUT_MS='600000'"));
        assert!(s.contains("CLAUDE_CONFIG_DIR="));
        assert!(!s.contains("ANTHROPIC_DEFAULT_OPUS_MODEL='"));
        assert!(s.trim_end().ends_with("exec claude \"$@\""));
    }

    #[test]
    fn bad_env_rejected() {
        assert!(parse_extra_env("1BAD=x").is_err());
        assert!(parse_extra_env("NOEQUALS").is_err());
    }
}
