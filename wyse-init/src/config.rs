//! Settings, read in the same order the old load-config script used:
//! built-in defaults, then /persist/wyse.conf, then the locked VPN settings
//! from the read-only image (always last, so nothing can override them).
//! Lines are `KEY=value`, `KEY="value"` or `KEY='value'`; `#` starts a comment.
use std::collections::HashMap;
use std::fs;
use std::path::Path;

pub struct Config(HashMap<String, String>);

impl Config {
    pub fn load() -> Config {
        let mut c = Config(HashMap::new());
        c.read("/etc/wyse/wyse.conf");
        c.read("/persist/wyse.conf");
        if Path::new("/rom/etc/wyse/vpn.conf").exists() {
            c.read("/rom/etc/wyse/vpn.conf");
        } else {
            c.read("/etc/wyse/vpn.conf");
        }
        c
    }

    fn read(&mut self, path: &str) {
        if let Ok(text) = fs::read_to_string(path) {
            self.parse(&text);
        }
    }

    fn parse(&mut self, text: &str) {
        for line in text.lines() {
            let line = line.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let Some((key, rest)) = line.split_once('=') else { continue };
            if key.is_empty() || !key.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_') {
                continue;
            }
            self.0.insert(key.to_string(), value(rest));
        }
    }

    /// The value, or "" when not set (like an unset shell variable).
    pub fn get(&self, key: &str) -> &str {
        self.0.get(key).map(String::as_str).unwrap_or("")
    }

    pub fn is(&self, key: &str, want: &str) -> bool {
        self.get(key) == want
    }

    /// The value split on spaces (like an unquoted `$VAR` in the shell).
    pub fn words(&self, key: &str) -> Vec<String> {
        self.get(key).split_whitespace().map(String::from).collect()
    }
}

fn value(rest: &str) -> String {
    for q in ['"', '\''] {
        if let Some(inner) = rest.strip_prefix(q) {
            return inner.split(q).next().unwrap_or("").to_string();
        }
    }
    rest.split_whitespace().next().unwrap_or("").to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_like_the_shell() {
        let mut c = Config(HashMap::new());
        c.parse(
            "# comment\nHOSTNAME=wyse\nNET_DNS=\"1.1.1.1 8.8.8.8\"\nTS_UP_ARGS='--ssh'\n\
             EMPTY=\"\"\nBAD KEY=x\nNTP=pool.ntp.org # trailing\n",
        );
        c.parse("HOSTNAME=\"wyse-test\"\n");
        assert_eq!(c.get("HOSTNAME"), "wyse-test");
        assert_eq!(c.words("NET_DNS"), ["1.1.1.1", "8.8.8.8"]);
        assert_eq!(c.get("TS_UP_ARGS"), "--ssh");
        assert_eq!(c.get("EMPTY"), "");
        assert_eq!(c.get("NTP"), "pool.ntp.org");
        assert_eq!(c.get("MISSING"), "");
        assert_eq!(c.get("BAD KEY"), "");
    }
}
