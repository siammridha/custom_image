//! A small JSON reader (RFC 8259), for the update server's replies. Writing
//! JSON is done with format! and `quote`.
use std::collections::BTreeMap;

#[derive(Debug, PartialEq, Clone)]
pub enum Json {
    Null,
    Bool(bool),
    Num(f64),
    Str(String),
    Arr(Vec<Json>),
    Obj(BTreeMap<String, Json>),
}

static NULL: Json = Json::Null;

impl Json {
    /// Member of an object, or element of an array by number. Null if
    /// missing, so lookups can be chained.
    pub fn get(&self, key: &str) -> &Json {
        match self {
            Json::Obj(m) => m.get(key).unwrap_or(&NULL),
            Json::Arr(a) => key.parse::<usize>().ok().and_then(|i| a.get(i)).unwrap_or(&NULL),
            _ => &NULL,
        }
    }

    /// Follow a path like "deployment/chunks/0/version".
    pub fn at(&self, path: &str) -> &Json {
        path.split('/').fold(self, |j, k| j.get(k))
    }

    pub fn str(&self) -> Option<&str> {
        match self {
            Json::Str(s) => Some(s),
            _ => None,
        }
    }

    /// A number, or a string of digits (hawkBit sends ids as strings).
    pub fn u64(&self) -> Option<u64> {
        match self {
            Json::Num(n) if *n >= 0.0 && n.fract() == 0.0 => Some(*n as u64),
            Json::Str(s) => s.parse().ok(),
            _ => None,
        }
    }
}

/// A JSON string literal for `s`.
pub fn quote(s: &str) -> String {
    let mut o = String::with_capacity(s.len() + 2);
    o.push('"');
    for c in s.chars() {
        match c {
            '"' => o.push_str("\\\""),
            '\\' => o.push_str("\\\\"),
            '\n' => o.push_str("\\n"),
            '\r' => o.push_str("\\r"),
            '\t' => o.push_str("\\t"),
            c if (c as u32) < 0x20 => o.push_str(&format!("\\u{:04x}", c as u32)),
            c => o.push(c),
        }
    }
    o.push('"');
    o
}

pub fn parse(s: &str) -> Result<Json, String> {
    let mut p = Parser { b: s.as_bytes(), i: 0, depth: 0 };
    let v = p.value()?;
    p.ws();
    if p.i != p.b.len() {
        return Err(format!("extra data at byte {}", p.i));
    }
    Ok(v)
}

struct Parser<'a> {
    b: &'a [u8],
    i: usize,
    depth: u32,
}

impl Parser<'_> {
    fn err<T>(&self, m: &str) -> Result<T, String> {
        Err(format!("{m} at byte {}", self.i))
    }

    fn ws(&mut self) {
        while self.i < self.b.len() && matches!(self.b[self.i], b' ' | b'\t' | b'\n' | b'\r') {
            self.i += 1;
        }
    }

    fn eat(&mut self, c: u8) -> bool {
        self.ws();
        if self.b.get(self.i) == Some(&c) {
            self.i += 1;
            true
        } else {
            false
        }
    }

    fn word(&mut self, w: &str, v: Json) -> Result<Json, String> {
        if self.b[self.i..].starts_with(w.as_bytes()) {
            self.i += w.len();
            Ok(v)
        } else {
            self.err("bad value")
        }
    }

    fn value(&mut self) -> Result<Json, String> {
        self.ws();
        match self.b.get(self.i) {
            None => self.err("unexpected end"),
            Some(b'{') => {
                self.nest()?;
                self.i += 1;
                let mut m = BTreeMap::new();
                if !self.eat(b'}') {
                    loop {
                        self.ws();
                        let k = self.string()?;
                        if !self.eat(b':') {
                            return self.err("expected ':'");
                        }
                        m.insert(k, self.value()?);
                        if self.eat(b'}') {
                            break;
                        }
                        if !self.eat(b',') {
                            return self.err("expected ',' or '}'");
                        }
                    }
                }
                self.depth -= 1;
                Ok(Json::Obj(m))
            }
            Some(b'[') => {
                self.nest()?;
                self.i += 1;
                let mut a = Vec::new();
                if !self.eat(b']') {
                    loop {
                        a.push(self.value()?);
                        if self.eat(b']') {
                            break;
                        }
                        if !self.eat(b',') {
                            return self.err("expected ',' or ']'");
                        }
                    }
                }
                self.depth -= 1;
                Ok(Json::Arr(a))
            }
            Some(b'"') => Ok(Json::Str(self.string()?)),
            Some(b't') => self.word("true", Json::Bool(true)),
            Some(b'f') => self.word("false", Json::Bool(false)),
            Some(b'n') => self.word("null", Json::Null),
            Some(_) => self.number(),
        }
    }

    fn nest(&mut self) -> Result<(), String> {
        self.depth += 1;
        if self.depth > 64 {
            return self.err("nested too deep");
        }
        Ok(())
    }

    fn number(&mut self) -> Result<Json, String> {
        let start = self.i;
        while self.i < self.b.len() && matches!(self.b[self.i], b'-' | b'+' | b'.' | b'e' | b'E' | b'0'..=b'9') {
            self.i += 1;
        }
        let t = std::str::from_utf8(&self.b[start..self.i]).unwrap_or("");
        match t.parse::<f64>() {
            Ok(n) if !t.is_empty() => Ok(Json::Num(n)),
            _ => {
                self.i = start;
                self.err("bad number")
            }
        }
    }

    fn hex4(&mut self) -> Result<u32, String> {
        let h = self.b.get(self.i..self.i + 4).and_then(|h| std::str::from_utf8(h).ok());
        match h.and_then(|h| u32::from_str_radix(h, 16).ok()) {
            Some(v) => {
                self.i += 4;
                Ok(v)
            }
            None => self.err("bad \\u escape"),
        }
    }

    fn string(&mut self) -> Result<String, String> {
        if self.b.get(self.i) != Some(&b'"') {
            return self.err("expected string");
        }
        self.i += 1;
        let mut out: Vec<u8> = Vec::new();
        loop {
            let Some(&c) = self.b.get(self.i) else { return self.err("unterminated string") };
            self.i += 1;
            match c {
                b'"' => break,
                b'\\' => {
                    let Some(&e) = self.b.get(self.i) else { return self.err("unterminated string") };
                    self.i += 1;
                    let ch = match e {
                        b'"' => '"',
                        b'\\' => '\\',
                        b'/' => '/',
                        b'b' => '\u{8}',
                        b'f' => '\u{c}',
                        b'n' => '\n',
                        b'r' => '\r',
                        b't' => '\t',
                        b'u' => {
                            let mut u = self.hex4()?;
                            if (0xd800..0xdc00).contains(&u) && self.b[self.i..].starts_with(b"\\u") {
                                self.i += 2;
                                let lo = self.hex4()?;
                                u = 0x10000 + ((u - 0xd800) << 10) + (lo.wrapping_sub(0xdc00) & 0x3ff);
                            }
                            char::from_u32(u).unwrap_or('\u{fffd}')
                        }
                        _ => return self.err("bad escape"),
                    };
                    let mut buf = [0; 4];
                    out.extend_from_slice(ch.encode_utf8(&mut buf).as_bytes());
                }
                c if c < 0x20 => return self.err("control character in string"),
                c => out.push(c),
            }
        }
        String::from_utf8(out).or_else(|_| self.err("bad UTF-8"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn deployment_base() {
        // The shape raptor documents (docs/src/reference/ddi-api.md).
        let s = r#"{
          "id": "7",
          "deployment": {
            "download": "forced", "update": "forced",
            "chunks": [
              { "part": "os", "version": "1.0", "name": "rootfs",
                "artifacts": [
                  { "filename": "rootfs.img", "size": 12345,
                    "hashes": { "sha1": "a", "md5": "b", "sha256": "c" },
                    "_links": { "download-http": {"href": "http://x/y"},
                                "md5sum-http":  {"href": "http://x/y.MD5SUM"} } }
                ] }
            ]
          },
          "actionHistory": { "status": "RUNNING", "messages": [] }
        }"#;
        let j = parse(s).unwrap();
        assert_eq!(j.get("id").u64(), Some(7));
        let a = j.at("deployment/chunks/0/artifacts/0");
        assert_eq!(a.get("size").u64(), Some(12345));
        assert_eq!(a.at("hashes/sha256").str(), Some("c"));
        assert_eq!(a.at("_links/download-http/href").str(), Some("http://x/y"));
        assert_eq!(j.at("deployment/chunks/0/version").str(), Some("1.0"));
        assert_eq!(j.at("deployment/chunks/1/version"), &Json::Null);
        assert_eq!(j.at("actionHistory/messages"), &Json::Arr(vec![]));
    }

    #[test]
    fn values() {
        assert_eq!(parse("[true,false,null,-1.5e2]").unwrap(), Json::Arr(vec![Json::Bool(true), Json::Bool(false), Json::Null, Json::Num(-150.0)]));
        assert_eq!(parse(r#""a\"\\\/\né😀""#).unwrap(), Json::Str("a\"\\/\né😀".into()));
        assert_eq!(parse(" {} ").unwrap(), Json::Obj(BTreeMap::new()));
        for bad in ["", "{", "[1,]", "{\"a\" 1}", "tru", "\"x", "1 2", "{\"a\":1,}", "\"\u{1}\""] {
            assert!(parse(bad).is_err(), "{bad:?}");
        }
        assert!(parse(&"[".repeat(100)).is_err());
    }

    #[test]
    fn quoting() {
        assert_eq!(quote("a\"b\\c\nd\u{1}"), r#""a\"b\\c\nd\u0001""#);
        let s = "x\"y\\z\n\té";
        assert_eq!(parse(&quote(s)).unwrap(), Json::Str(s.into()));
    }
}
