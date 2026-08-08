use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::fs::File;
use std::io::Write;
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

struct LoggerInner {
    file: File,
    prev_hash: String,
}

pub struct Logger {
    inner: Mutex<LoggerInner>,
}

impl Logger {
    pub fn new(path: &str) -> std::io::Result<Logger> {
        let file = std::fs::OpenOptions::new()
            .create(true)
            .write(true)
            .truncate(true)
            .open(path)?;
        Ok(Logger {
            inner: Mutex::new(LoggerInner {
                file,
                prev_hash: "0".repeat(64),
            }),
        })
    }

    pub fn log(&self, mut fields: Value) {
        let mut guard = match self.inner.lock() {
            Ok(g) => g,
            Err(_) => return,
        };

        let ts = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);

        if let Value::Object(map) = &mut fields {
            map.insert("ts".to_string(), json!(ts));
            map.insert("prev_hash".to_string(), json!(guard.prev_hash.clone()));
        }

        let serialized = serde_json::to_string(&fields).unwrap_or_default();
        let mut hasher = Sha256::new();
        hasher.update(guard.prev_hash.as_bytes());
        hasher.update(serialized.as_bytes());
        let hash = format!("{:x}", hasher.finalize());

        let mut final_obj = fields;
        if let Value::Object(map) = &mut final_obj {
            map.insert("hash".to_string(), json!(hash.clone()));
        }

        let line = serde_json::to_string(&final_obj).unwrap_or_default();
        let _ = writeln!(guard.file, "{}", line);
        guard.prev_hash = hash;
    }
}

pub fn verify_chain(path: &str) -> Result<u64, String> {
    let content = std::fs::read_to_string(path).map_err(|e| e.to_string())?;
    let mut prev_hash = "0".repeat(64);
    let mut count: u64 = 0;

    for (idx, line) in content.lines().enumerate() {
        if line.trim().is_empty() {
            continue;
        }
        let mut record: Value = serde_json::from_str(line)
            .map_err(|e| format!("linia {}: nieprawidlowy json: {}", idx + 1, e))?;

        let stored_hash = record
            .get("hash")
            .and_then(|v| v.as_str())
            .ok_or_else(|| format!("linia {}: brak pola hash", idx + 1))?
            .to_string();
        let stored_prev = record
            .get("prev_hash")
            .and_then(|v| v.as_str())
            .ok_or_else(|| format!("linia {}: brak pola prev_hash", idx + 1))?
            .to_string();

        if stored_prev != prev_hash {
            return Err(format!(
                "linia {}: lancuch przerwany (oczekiwano prev_hash {}, jest {})",
                idx + 1,
                prev_hash,
                stored_prev
            ));
        }

        if let Value::Object(map) = &mut record {
            map.remove("hash");
        }
        let serialized = serde_json::to_string(&record).unwrap_or_default();
        let mut hasher = Sha256::new();
        hasher.update(stored_prev.as_bytes());
        hasher.update(serialized.as_bytes());
        let computed = format!("{:x}", hasher.finalize());

        if computed != stored_hash {
            return Err(format!(
                "linia {}: hash nie zgadza sie, log zostal zmodyfikowany",
                idx + 1
            ));
        }

        prev_hash = stored_hash;
        count += 1;
    }

    Ok(count)
}
