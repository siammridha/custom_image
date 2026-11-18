//! Computes the device's VPN and SSH keys from one secret and writes them
//! into the image, so the keys are the same after every boot.
//!
//!   device-keys <secret file> <target dir>
//!
//! The secret file holds 32 random bytes as hex; it is made if missing.
//! Each key is SHA-256(secret + label). Formats follow the programs' source:
//!   - NetBird 0.83.1 default.json: PrivateKey (WireGuard, base64) and SSHKey
//!     (ed25519, PKCS8 PEM, as Go's x509.MarshalPKCS8PrivateKey makes it) as
//!     made by EnsureIdentity; NetBird fills in the rest.
//!   - Tailscale 1.104.7 tailscaled.state (FileStore: JSON map, values base64):
//!     "_machinekey" = "privkey:<hex>", clamped (types/key/machine.go).
//!   - dropbear 2026.94 ed25519 host key (buf_put_ed25519_priv_key):
//!     string "ssh-ed25519", uint32 64, private seed, public key.
use base64::engine::general_purpose::STANDARD as B64;
use base64::Engine;
use ed25519_dalek::SigningKey;
use sha2::{Digest, Sha256};
use std::fs;
use std::io::{ErrorKind, Read};
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt};
use std::path::Path;
use std::process::exit;

fn die(m: String) -> ! {
    eprintln!("device-keys: {m}");
    exit(1);
}

fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

fn unhex(s: &str) -> Option<Vec<u8>> {
    if s.len() % 2 != 0 {
        return None;
    }
    (0..s.len()).step_by(2).map(|i| u8::from_str_radix(s.get(i..i + 2)?, 16).ok()).collect()
}

fn write(path: &str, data: &[u8]) {
    let dir = Path::new(path).parent().unwrap();
    match fs::DirBuilder::new().mode(0o700).create(dir) {
        Err(e) if e.kind() != ErrorKind::AlreadyExists => die(format!("{}: {e}", dir.display())),
        _ => {}
    }
    let set = fs::set_permissions(dir, fs::Permissions::from_mode(0o700));
    set.unwrap_or_else(|e| die(format!("{}: {e}", dir.display())));
    let _ = fs::remove_file(path);
    fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)
        .and_then(|mut f| std::io::Write::write_all(&mut f, data))
        .unwrap_or_else(|e| die(format!("{path}: {e}")));
}

fn read_secret(path: &str) -> [u8; 32] {
    let mut s = [0u8; 32];
    match fs::read_to_string(path) {
        Ok(t) => match unhex(t.trim()) {
            Some(b) if b.len() == 32 => s.copy_from_slice(&b),
            _ => die(format!("{path}: want 32 bytes as hex")),
        },
        Err(e) if e.kind() == ErrorKind::NotFound => {
            fs::File::open("/dev/urandom")
                .and_then(|mut f| f.read_exact(&mut s))
                .unwrap_or_else(|e| die(format!("/dev/urandom: {e}")));
            fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .open(path)
                .and_then(|mut f| std::io::Write::write_all(&mut f, format!("{}\n", hex(&s)).as_bytes()))
                .unwrap_or_else(|e| die(format!("{path}: {e}")));
            println!("device-keys: made new secret {path}");
        }
        Err(e) => die(format!("{path}: {e}")),
    }
    s
}

fn derive(secret: &[u8; 32], label: &str) -> [u8; 32] {
    Sha256::new().chain_update(secret).chain_update(label).finalize().into()
}

/// Curve25519 private key clamping (WireGuard, Tailscale).
fn clamp(mut k: [u8; 32]) -> [u8; 32] {
    k[0] &= 248;
    k[31] = (k[31] & 127) | 64;
    k
}

/// SSH wire "string": 4-byte big-endian length, then the bytes.
fn ssh_string(b: &[u8]) -> Vec<u8> {
    let mut v = (b.len() as u32).to_be_bytes().to_vec();
    v.extend_from_slice(b);
    v
}

/// PEM "PRIVATE KEY" with the PKCS8 form Go uses for ed25519 (RFC 8410:
/// version 0, algorithm 1.3.101.112, the seed in an OCTET STRING).
fn pkcs8_pem(seed: &[u8; 32]) -> String {
    let mut der = vec![
        0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20,
    ];
    der.extend_from_slice(seed);
    let b = B64.encode(der);
    let mut pem = String::from("-----BEGIN PRIVATE KEY-----\n");
    for line in b.as_bytes().chunks(64) {
        pem.push_str(std::str::from_utf8(line).unwrap());
        pem.push('\n');
    }
    pem.push_str("-----END PRIVATE KEY-----\n");
    pem
}

/// JSON string. The values here are base64 and PEM text: only the
/// newlines need escaping.
fn json_str(s: &str) -> String {
    format!("\"{}\"", s.replace('\\', "\\\\").replace('"', "\\\"").replace('\n', "\\n"))
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 3 {
        die("usage: device-keys <secret file> <target dir>".into());
    }
    let secret = read_secret(&args[1]);
    let t = &args[2];

    // NetBird
    let wg = B64.encode(clamp(derive(&secret, "netbird-wg")));
    let ssh = pkcs8_pem(&derive(&secret, "netbird-ssh"));
    let nb = format!(
        "{{\n    \"PrivateKey\": {},\n    \"SSHKey\": {}\n}}\n",
        json_str(&wg),
        json_str(&ssh)
    );
    write(&format!("{t}/var/lib/netbird/default.json"), nb.as_bytes());

    // Tailscale
    let mk = format!("privkey:{}", hex(&clamp(derive(&secret, "tailscale-machine"))));
    let ts = format!("{{\n    \"_machinekey\": {}\n}}\n", json_str(&B64.encode(mk)));
    write(&format!("{t}/var/lib/tailscale/tailscaled.state"), ts.as_bytes());

    // dropbear
    let key = SigningKey::from_bytes(&derive(&secret, "ssh"));
    let public = key.verifying_key().to_bytes();
    let mut f = ssh_string(b"ssh-ed25519");
    f.extend_from_slice(&64u32.to_be_bytes());
    f.extend_from_slice(&key.to_bytes());
    f.extend_from_slice(&public);
    write(&format!("{t}/etc/wyse/dropbear/dropbear_ed25519_host_key"), &f);

    let mut blob = ssh_string(b"ssh-ed25519");
    blob.extend(ssh_string(&public));
    println!("device-keys: ssh host key: ssh-ed25519 {}", B64.encode(blob));
}
