//! Computers this KVJ has paired with, kept in `<data>/bluetooth.json`. Each
//! install has one random token it sends in HELLO; a token, not a Bluetooth
//! address (a Mac's rotates), is what both sides remember.
use anyhow::Result;
use serde::{Deserialize, Serialize};
use std::{fs, path::Path};

#[derive(Clone, Serialize, Deserialize)]
pub struct Known {
    pub token: String,
    pub name: String,
    /// What the other computer is: "dj" (it sends to us) or "receiver".
    pub role: String,
    /// Its transport id when last connected, to find it again without asking.
    #[serde(default)]
    pub id: String,
    #[serde(default)]
    pub at_ms: f64,
}
#[derive(Default, Serialize, Deserialize)]
pub struct Pairing {
    #[serde(default)]
    pub token: String,
    #[serde(default)]
    pub known: Vec<Known>,
}
const FILE: &str = "bluetooth.json";
pub fn valid_token(token: &str) -> bool {
    token.len() == 32 && token.bytes().all(|b| b.is_ascii_hexdigit())
}
impl Pairing {
    /// The saved pairing, with a token made (and saved) on first use.
    pub fn open(dir: &Path) -> Self {
        let mut pairing: Self = fs::read(dir.join(FILE))
            .ok()
            .and_then(|bytes| serde_json::from_slice(&bytes).ok())
            .unwrap_or_default();
        pairing.known.retain(|k| valid_token(&k.token) && ["dj", "receiver"].contains(&k.role.as_str()));
        if !valid_token(&pairing.token) {
            pairing.token = crate::document::id();
            if let Err(error) = pairing.save(dir) {
                tracing::warn!("saving the Bluetooth pairing failed: {error:#}");
            }
        }
        pairing
    }
    pub fn save(&self, dir: &Path) -> Result<()> {
        fs::create_dir_all(dir)?;
        let tmp = dir.join(format!("{FILE}.tmp"));
        fs::write(&tmp, serde_json::to_vec_pretty(self)?)?;
        crate::document::replace(&tmp, &dir.join(FILE))?;
        Ok(())
    }
    pub fn knows(&self, token: &str, role: &str) -> bool {
        self.known.iter().any(|k| k.token == token && k.role == role)
    }
    /// Remember (or refresh) a paired computer; the newest comes first.
    pub fn remember(&mut self, known: Known) {
        self.known.retain(|k| !(k.token == known.token && k.role == known.role));
        self.known.insert(0, known);
        self.known.truncate(32);
    }
    pub fn forget(&mut self, token: &str) -> bool {
        let before = self.known.len();
        self.known.retain(|k| k.token != token);
        before != self.known.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn token_is_made_once_and_known_devices_round_trip() {
        let dir = std::env::temp_dir().join(format!("kvj-pairing-{}", crate::document::id()));
        let first = Pairing::open(&dir);
        assert!(valid_token(&first.token));
        let mut again = Pairing::open(&dir);
        assert_eq!(again.token, first.token);
        let peer = crate::document::id();
        again.remember(Known { token: peer.clone(), name: "DJ".into(), role: "dj".into(), id: "x".into(), at_ms: 1. });
        again.remember(Known { token: peer.clone(), name: "DJ 2".into(), role: "dj".into(), id: "y".into(), at_ms: 2. });
        again.save(&dir).unwrap();
        let reopened = Pairing::open(&dir);
        assert_eq!(reopened.known.len(), 1);
        assert_eq!(reopened.known[0].name, "DJ 2");
        assert!(reopened.knows(&peer, "dj") && !reopened.knows(&peer, "receiver"));
        let mut forgotten = reopened;
        assert!(forgotten.forget(&peer) && forgotten.known.is_empty());
        let _ = fs::remove_dir_all(dir);
    }
}
