pub struct Config {
    root: toml::Value,
}

impl Config {
    pub fn parse(src: &str) -> Result<Config, String> {
        let root: toml::Value = toml::from_str(src).map_err(|e| e.to_string())?;
        Ok(Config { root })
    }

    pub fn get(&self, path: &str) -> Option<String> {
        let mut parts = path.splitn(2, '.');
        let section = parts.next()?;
        let key = parts.next()?;
        let value = self.root.get(section)?.get(key)?;
        match value {
            toml::Value::String(s) => Some(s.clone()),
            toml::Value::Integer(i) => Some(i.to_string()),
            toml::Value::Float(f) => Some(f.to_string()),
            toml::Value::Boolean(b) => Some(b.to_string()),
            _ => None,
        }
    }

    #[allow(dead_code)]
    pub fn get_list(&self, path: &str) -> Option<Vec<String>> {
        let mut parts = path.splitn(2, '.');
        let section = parts.next()?;
        let key = parts.next()?;
        let value = self.root.get(section)?.get(key)?;
        match value {
            toml::Value::Array(items) => Some(
                items
                    .iter()
                    .filter_map(|v| v.as_str().map(|s| s.to_string()))
                    .collect(),
            ),
            _ => None,
        }
    }

    pub fn interpolate(&self, s: &str) -> String {
        let mut out = String::with_capacity(s.len());
        let bytes = s.as_bytes();
        let mut i = 0;
        while i < bytes.len() {
            if i + 1 < bytes.len() && bytes[i] == b'{' && bytes[i + 1] == b'{' {
                let start = i + 2;
                let mut j = start;
                while j + 1 < bytes.len() && !(bytes[j] == b'}' && bytes[j + 1] == b'}') {
                    j += 1;
                }
                let key = s[start..j].trim();
                if let Some(val) = self.get(key) {
                    out.push_str(&val);
                }
                i = j + 2;
            } else {
                out.push(bytes[i] as char);
                i += 1;
            }
        }
        out
    }
}
