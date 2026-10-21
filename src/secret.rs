//! API keys live only in the macOS Keychain (service = SERVICE, account = profile slug).
//! The launcher scripts read them back at run time with `/usr/bin/security`,
//! so no key is ever written to disk in plain text.

pub const SERVICE: &str = "claude-profiles";

#[cfg(target_os = "macos")]
mod imp {
    use super::SERVICE;
    use anyhow::{Context, Result};
    use security_framework::passwords;

    // errSecItemNotFound
    const NOT_FOUND: i32 = -25300;

    pub fn set(account: &str, key: &str) -> Result<()> {
        passwords::set_generic_password(SERVICE, account, key.as_bytes())
            .context("Không lưu được key vào Keychain")
    }

    pub fn get(account: &str) -> Result<Option<String>> {
        match passwords::get_generic_password(SERVICE, account) {
            Ok(bytes) => Ok(Some(String::from_utf8(bytes)?)),
            Err(e) if e.code() == NOT_FOUND => Ok(None),
            Err(e) => Err(e).context("Không đọc được Keychain"),
        }
    }

    pub fn delete(account: &str) -> Result<()> {
        match passwords::delete_generic_password(SERVICE, account) {
            Ok(()) => Ok(()),
            Err(e) if e.code() == NOT_FOUND => Ok(()),
            Err(e) => Err(e).context("Không xóa được key trong Keychain"),
        }
    }
}

/// Fallback for non-macOS builds (lets the UI compile and run for development).
/// Keys are kept in memory only.
#[cfg(not(target_os = "macos"))]
mod imp {
    use anyhow::Result;
    use std::collections::HashMap;
    use std::sync::Mutex;

    static MEM: Mutex<Option<HashMap<String, String>>> = Mutex::new(None);

    pub fn set(account: &str, key: &str) -> Result<()> {
        MEM.lock().unwrap().get_or_insert_with(HashMap::new).insert(account.into(), key.into());
        Ok(())
    }
    pub fn get(account: &str) -> Result<Option<String>> {
        Ok(MEM.lock().unwrap().as_ref().and_then(|m| m.get(account).cloned()))
    }
    pub fn delete(account: &str) -> Result<()> {
        if let Some(m) = MEM.lock().unwrap().as_mut() {
            m.remove(account);
        }
        Ok(())
    }
}

pub use imp::{delete, get, set};
