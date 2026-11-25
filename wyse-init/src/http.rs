//! A small HTTP/1.1 client (RFC 9112) for the update server: plain http://
//! only (it is reached over NetBird, which encrypts). One request per
//! connection. Bodies with Content-Length, chunked, or up to the close.
use std::io::{self, BufRead, BufReader, Read, Write};
use std::net::{TcpStream, ToSocketAddrs};
use std::time::Duration;

#[derive(Debug, PartialEq)]
pub struct Url {
    pub host: String,
    pub port: u16,
    /// Path and query, starting with '/'.
    pub path: String,
}

pub fn parse_url(u: &str) -> Result<Url, String> {
    let rest = u.strip_prefix("http://").ok_or_else(|| format!("{u}: only http:// URLs are supported"))?;
    let (hostport, path) = match rest.find(['/', '?']) {
        Some(i) => (&rest[..i], &rest[i..]),
        None => (rest, "/"),
    };
    let path = if path.starts_with('?') { format!("/{path}") } else { path.to_string() };
    let port = |p: &str| p.parse::<u16>().map_err(|_| format!("{u}: bad port"));
    let (host, port) = if hostport.starts_with('[') {
        // [IPv6 address]:port
        let end = hostport.find(']').ok_or_else(|| format!("{u}: bad URL"))? + 1;
        match &hostport[end..] {
            "" => (&hostport[..end], 80),
            p => (&hostport[..end], port(p.strip_prefix(':').unwrap_or("x"))?),
        }
    } else {
        match hostport.rsplit_once(':') {
            Some((h, p)) => (h, port(p)?),
            None => (hostport, 80),
        }
    };
    if host.is_empty() || host.contains(['@', ' ']) || path.contains([' ', '\r', '\n']) {
        return Err(format!("{u}: bad URL"));
    }
    Ok(Url { host: host.to_string(), port, path })
}

enum Body {
    Fixed(u64),
    Chunked { left: u64, done: bool },
    Close,
}

pub struct Response {
    pub status: u16,
    /// Content-Length, if the server sent one.
    pub length: Option<u64>,
    r: BufReader<TcpStream>,
    body: Body,
}

/// Send a request and read the reply's status line and headers. The body is
/// read from the Response (it implements Read).
pub fn request(method: &str, url: &str, headers: &[(&str, &str)], body: Option<&str>) -> Result<Response, String> {
    let u = parse_url(url)?;
    let name = u.host.trim_start_matches('[').trim_end_matches(']');
    let addrs: Vec<_> = (name, u.port)
        .to_socket_addrs()
        .map_err(|e| format!("{}: {e}", u.host))?
        .collect();
    let mut last = format!("{}: no address", u.host);
    let mut stream = None;
    for a in addrs {
        match TcpStream::connect_timeout(&a, Duration::from_secs(30)) {
            Ok(s) => {
                stream = Some(s);
                break;
            }
            Err(e) => last = format!("{a}: {e}"),
        }
    }
    let mut s = stream.ok_or(last)?;
    // A stalled server must not stop the updater for good.
    let _ = s.set_read_timeout(Some(Duration::from_secs(120)));
    let _ = s.set_write_timeout(Some(Duration::from_secs(120)));

    let host = if u.port == 80 { u.host.clone() } else { format!("{}:{}", u.host, u.port) };
    let mut req = format!("{method} {} HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\nUser-Agent: wyse-init\r\n", u.path);
    for (k, v) in headers {
        if v.contains(['\r', '\n']) {
            return Err(format!("bad header value for {k}"));
        }
        req.push_str(&format!("{k}: {v}\r\n"));
    }
    if let Some(b) = body {
        req.push_str(&format!("Content-Length: {}\r\n\r\n{b}", b.len()));
    } else {
        req.push_str("\r\n");
    }
    s.write_all(req.as_bytes()).map_err(|e| format!("send: {e}"))?;
    read_head(BufReader::with_capacity(64 * 1024, s), method == "HEAD")
}

fn line<R: BufRead>(r: &mut R) -> io::Result<String> {
    let mut v = Vec::new();
    r.by_ref().take(8192).read_until(b'\n', &mut v)?;
    if !v.ends_with(b"\n") {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "header line too long or cut off"));
    }
    Ok(String::from_utf8_lossy(&v).trim_end_matches(['\r', '\n']).to_string())
}

fn read_head(mut r: BufReader<TcpStream>, head: bool) -> Result<Response, String> {
    let (status, length, chunked) = parse_head(&mut r)?;
    let body = if head || status == 204 || status == 304 || (100..200).contains(&status) {
        Body::Fixed(0)
    } else if chunked {
        Body::Chunked { left: 0, done: false }
    } else if let Some(n) = length {
        Body::Fixed(n)
    } else {
        Body::Close
    };
    Ok(Response { status, length: if chunked { None } else { length }, r, body })
}

/// Status line and headers: (status, Content-Length, chunked).
fn parse_head<R: BufRead>(r: &mut R) -> Result<(u16, Option<u64>, bool), String> {
    let st = line(r).map_err(|e| format!("reply: {e}"))?;
    let mut f = st.split(' ');
    let (v, code) = (f.next().unwrap_or(""), f.next().unwrap_or(""));
    let status: u16 = match code.parse() {
        Ok(c) if v.starts_with("HTTP/1.") => c,
        _ => return Err(format!("bad reply: {st:?}")),
    };
    let (mut length, mut chunked) = (None, false);
    for _ in 0..100 {
        let h = line(r).map_err(|e| format!("reply: {e}"))?;
        if h.is_empty() {
            return Ok((status, length, chunked));
        }
        let Some((k, v)) = h.split_once(':') else { continue };
        let (k, v) = (k.trim().to_ascii_lowercase(), v.trim());
        if k == "content-length" {
            length = Some(v.parse().map_err(|_| format!("bad Content-Length {v:?}"))?);
        } else if k == "transfer-encoding" && v.to_ascii_lowercase().contains("chunked") {
            chunked = true;
        }
    }
    Err("too many headers".into())
}

impl Read for Response {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        let bad = |m: &str| io::Error::new(io::ErrorKind::InvalidData, m.to_string());
        match &mut self.body {
            Body::Fixed(0) => Ok(0),
            Body::Fixed(left) => {
                let n = (*left).min(buf.len() as u64) as usize;
                let got = self.r.read(&mut buf[..n])?;
                if got == 0 {
                    return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "connection closed early"));
                }
                *left -= got as u64;
                Ok(got)
            }
            Body::Close => self.r.read(buf),
            Body::Chunked { left, done } => {
                if *done {
                    return Ok(0);
                }
                if *left == 0 {
                    let l = line(&mut self.r)?;
                    let size = l.split(';').next().unwrap_or("").trim();
                    *left = u64::from_str_radix(size, 16).map_err(|_| bad("bad chunk size"))?;
                    if *left == 0 {
                        // Trailers, up to the empty line.
                        while !line(&mut self.r)?.is_empty() {}
                        *done = true;
                        return Ok(0);
                    }
                }
                let n = (*left).min(buf.len() as u64) as usize;
                let got = self.r.read(&mut buf[..n])?;
                if got == 0 {
                    return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "connection closed early"));
                }
                *left -= got as u64;
                if *left == 0 && !line(&mut self.r)?.is_empty() {
                    return Err(bad("no CRLF after chunk"));
                }
                Ok(got)
            }
        }
    }
}

impl Response {
    /// The whole body as text (at most `max` bytes).
    pub fn text(mut self, max: u64) -> Result<String, String> {
        let mut v = Vec::new();
        self.by_ref().take(max + 1).read_to_end(&mut v).map_err(|e| format!("reply body: {e}"))?;
        if v.len() as u64 > max {
            return Err(format!("reply larger than {max} bytes"));
        }
        String::from_utf8(v).map_err(|_| "reply is not UTF-8".into())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;
    use std::net::TcpListener;
    use std::thread;

    #[test]
    fn urls() {
        assert_eq!(
            parse_url("http://10.0.0.1:8088/DEFAULT/controller/v1/a?x=1").unwrap(),
            Url { host: "10.0.0.1".into(), port: 8088, path: "/DEFAULT/controller/v1/a?x=1".into() }
        );
        assert_eq!(parse_url("http://ota.lan").unwrap(), Url { host: "ota.lan".into(), port: 80, path: "/".into() });
        assert_eq!(parse_url("http://h?q").unwrap().path, "/?q");
        assert_eq!(parse_url("http://[fd00::1]:81/x").unwrap(), Url { host: "[fd00::1]".into(), port: 81, path: "/x".into() });
        for bad in ["https://h/", "ftp://h", "http://", "http://h:x/", "http://u@h/", "http://h/a b"] {
            assert!(parse_url(bad).is_err(), "{bad}");
        }
    }

    #[test]
    fn heads() {
        let mut c = Cursor::new(b"HTTP/1.1 200 OK\r\nContent-Length: 12\r\nX: y\r\n\r\n".to_vec());
        assert_eq!(parse_head(&mut c).unwrap(), (200, Some(12), false));
        let mut c = Cursor::new(b"HTTP/1.1 404 Not Found\r\ntransfer-encoding: chunked\r\n\r\n".to_vec());
        assert_eq!(parse_head(&mut c).unwrap(), (404, None, true));
        let mut c = Cursor::new(b"SSH-2.0-dropbear\r\n".to_vec());
        assert!(parse_head(&mut c).is_err());
        let mut c = Cursor::new(b"HTTP/1.1 200 OK\r\nContent-Length: 1".to_vec());
        assert!(parse_head(&mut c).is_err());
    }

    /// A one-shot server that sends `reply` and returns the request it got.
    fn serve(reply: &'static [u8]) -> (String, thread::JoinHandle<String>) {
        let l = TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://127.0.0.1:{}/p", l.local_addr().unwrap().port());
        let h = thread::spawn(move || {
            let (mut s, _) = l.accept().unwrap();
            let mut r = BufReader::new(s.try_clone().unwrap());
            let mut req = String::new();
            loop {
                let l = line(&mut r).unwrap();
                if l.is_empty() {
                    break;
                }
                req.push_str(&l);
                req.push('\n');
            }
            s.write_all(reply).unwrap();
            req
        });
        (url, h)
    }

    #[test]
    fn fixed_and_chunked() {
        let (url, h) = serve(b"HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello");
        let r = request("GET", &url, &[("Authorization", "TargetToken t")], None).unwrap();
        assert_eq!((r.status, r.length), (200, Some(5)));
        assert_eq!(r.text(100).unwrap(), "hello");
        let req = h.join().unwrap();
        assert!(req.starts_with("GET /p HTTP/1.1\nHost: 127.0.0.1:"), "{req}");
        assert!(req.contains("Authorization: TargetToken t\n"));

        let (url, h) = serve(b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3;x=1\r\nabc\r\n2\r\nde\r\n0\r\nT: 1\r\n\r\n");
        assert_eq!(request("GET", &url, &[], None).unwrap().text(100).unwrap(), "abcde");
        h.join().unwrap();

        let (url, h) = serve(b"HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nshort");
        assert!(request("GET", &url, &[], None).unwrap().text(100).is_err());
        h.join().unwrap();

        let (url, h) = serve(b"HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello");
        assert!(request("GET", &url, &[], None).unwrap().text(4).is_err());
        h.join().unwrap();
    }
}
