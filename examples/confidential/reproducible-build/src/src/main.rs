mod attest;
mod cms;
mod http;
mod kms;
mod readings;

use std::io::{Read, Write};
use std::net::TcpListener;
use std::process::ExitCode;

use attest::Attester;
use kms::Kms;

/// The one string `changed-source.sh` edits to test reproducible-build tooling.
const BANNER: &str = "reproducible-build decrypt v1";

// ── JSON helpers ──────────────────────────────────────────────────────────────

/// Escape a string for safe embedding inside a JSON string literal.
/// Handles `"`, `\`, and all control characters including newlines.
fn json_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out
}

fn sha256_hex(data: &[u8]) -> String {
    use sha2::{Digest, Sha256};
    let hash = Sha256::digest(data);
    hash.iter().map(|b| format!("{b:02x}")).collect()
}

fn readings_json(r: &[(&str, String)]) -> String {
    let fields: Vec<String> = r
        .iter()
        .map(|(k, v)| format!(r#""{k}":"{}""#, json_escape(v)))
        .collect();
    format!("{{{}}}", fields.join(","))
}

// ── Request handler ───────────────────────────────────────────────────────────

/// Handle one HTTP request; write diagnostics to `log`.
/// Returns `(status, reason_phrase, json_body)`.
fn handle(
    req: &http::Request,
    attester: &dyn Attester,
    kms: &dyn Kms,
    log: &mut dyn Write,
) -> (u16, &'static str, String) {
    if req.method == "GET" && req.path == "/readings" {
        return (200, "OK", readings_json(&readings::collect()));
    }

    if req.method != "PUT" || req.path != "/decrypt" {
        return (
            404,
            "Not Found",
            r#"{"ok":false,"error":"not-found"}"#.to_string(),
        );
    }

    const MAX_BODY: usize = 6144;
    if req.body.is_empty() || req.body.len() > MAX_BODY {
        return (
            400,
            "Bad Request",
            r#"{"ok":false,"error":"bad-input"}"#.to_string(),
        );
    }

    let key = match cms::RecipientKey::generate() {
        Ok(k) => k,
        Err(_) => {
            return (
                503,
                "Service Unavailable",
                r#"{"ok":false,"error":"key-gen-failed"}"#.to_string(),
            );
        }
    };

    let pub_key_der = match key.public_key_der() {
        Ok(d) => d,
        Err(_) => {
            return (
                503,
                "Service Unavailable",
                r#"{"ok":false,"error":"key-gen-failed"}"#.to_string(),
            );
        }
    };

    let attestation_doc = match attester.attest(&pub_key_der) {
        Ok(d) => d,
        Err(e) => {
            // Include NSM diagnostics to help operators understand why the device is absent.
            let full = format!("{e}\n{}", attest::nsm_diagnostics());
            let diag = json_escape(&full);
            return (
                503,
                "Service Unavailable",
                format!(r#"{{"ok":false,"error":"no-nsm","diagnostics":"{diag}"}}"#),
            );
        }
    };

    let cms_bytes = match kms.decrypt(&req.body, &attestation_doc) {
        Ok(b) => b,
        Err(e) if e.denied => {
            let code = json_escape(&e.code);
            let _ = writeln!(log, "kms-denied code={}", e.code);
            return (
                403,
                "Forbidden",
                format!(r#"{{"ok":false,"error":"kms-denied","code":"{code}"}}"#),
            );
        }
        Err(e) => {
            let code = json_escape(&e.code);
            let _ = writeln!(log, "kms-error code={} message={}", e.code, e.message);
            return (
                502,
                "Bad Gateway",
                format!(r#"{{"ok":false,"error":"kms-error","code":"{code}"}}"#),
            );
        }
    };

    let plaintext = match key.unwrap(&cms_bytes) {
        Ok(p) => p,
        Err(_) => {
            return (
                500,
                "Internal Server Error",
                r#"{"ok":false,"error":"unwrap-failed"}"#.to_string(),
            );
        }
    };

    let hex = sha256_hex(&plaintext);
    let _ = writeln!(log, "decrypted sha256={hex}");

    (200, "OK", format!(r#"{{"ok":true,"sha256":"{hex}"}}"#))
}

// ── Connection loop ───────────────────────────────────────────────────────────

fn serve_connection_with<R: Read, W: Write>(
    r: &mut R,
    w: &mut W,
    attester: &dyn Attester,
    kms: &dyn Kms,
) {
    let mut log = std::io::stdout();
    match http::read_request(r) {
        Ok(Some(req)) => {
            let (status, reason, body) = handle(&req, attester, kms, &mut log);
            let _ = http::write_response(w, status, reason, "application/json", body.as_bytes());
        }
        Ok(None) => {}
        Err(_) => {
            let body = r#"{"ok":false,"error":"bad-request"}"#;
            let _ =
                http::write_response(w, 400, "Bad Request", "application/json", body.as_bytes());
        }
    }
}

// ── Entry point ───────────────────────────────────────────────────────────────

fn main() -> ExitCode {
    readings::log_readings();
    println!("{BANNER}");

    // ponytail: bind defaults to loopback; set LISTEN_ADDR in the pod manifest for a wider bind
    let addr = std::env::var("LISTEN_ADDR").unwrap_or_else(|_| "127.0.0.1:8080".to_string());

    let sdk_kms = match kms::SdkKms::new() {
        Ok(k) => k,
        Err(e) => {
            eprintln!("error: KMS init failed: {e}");
            return ExitCode::FAILURE;
        }
    };

    let listener = match TcpListener::bind(&addr) {
        Ok(l) => l,
        Err(e) => {
            eprintln!("error: bind {addr}: {e}");
            return ExitCode::FAILURE;
        }
    };

    println!("listening on {addr}");

    let attester = attest::Nsm;
    for stream in listener.incoming() {
        match stream {
            Ok(s) => {
                // Guard against a stalled client holding the single-threaded server indefinitely.
                if let Err(e) = s.set_read_timeout(Some(std::time::Duration::from_secs(5))) {
                    eprintln!("set_read_timeout: {e}");
                }
                // TcpStream implements Read and Write for &TcpStream; no clone needed.
                serve_connection_with(&mut &s, &mut &s, &attester, &sdk_kms);
            }
            Err(e) => eprintln!("accept: {e}"),
        }
    }

    ExitCode::SUCCESS
}

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::attest::Attester;
    use crate::kms::{Kms, KmsError};

    // ── Fakes ──────────────────────────────────────────────────────────────────

    /// Echoes `public_key_der` as the attestation doc so FakeKms can parse it.
    struct FakeAttester;
    impl Attester for FakeAttester {
        fn attest(&self, public_key_der: &[u8]) -> Result<Vec<u8>, String> {
            Ok(public_key_der.to_vec())
        }
    }

    struct FailAttester(String);
    impl Attester for FailAttester {
        fn attest(&self, _: &[u8]) -> Result<Vec<u8>, String> {
            Err(self.0.clone())
        }
    }

    /// Receives `attestation_doc` = raw SPKI DER (echoed by FakeAttester) and builds
    /// a CMS message encrypted to that public key.
    struct FakeKms {
        plaintext: Vec<u8>,
    }
    impl Kms for FakeKms {
        fn decrypt(&self, _ciphertext: &[u8], attestation_doc: &[u8]) -> Result<Vec<u8>, KmsError> {
            Ok(crate::cms::test_support::kms_shaped_cms(
                attestation_doc,
                &self.plaintext,
            ))
        }
    }

    struct ErrKms {
        code: &'static str,
        message: &'static str,
        denied: bool,
    }
    impl Kms for ErrKms {
        fn decrypt(&self, _: &[u8], _: &[u8]) -> Result<Vec<u8>, KmsError> {
            Err(KmsError {
                code: self.code.to_string(),
                message: self.message.to_string(),
                denied: self.denied,
            })
        }
    }

    struct DeniedKms;
    impl Kms for DeniedKms {
        fn decrypt(&self, _: &[u8], _: &[u8]) -> Result<Vec<u8>, KmsError> {
            Err(KmsError {
                code: "AccessDeniedException".to_string(),
                message: String::new(),
                denied: true,
            })
        }
    }

    fn put_decrypt(body: &[u8]) -> http::Request {
        http::Request {
            method: "PUT".to_string(),
            path: "/decrypt".to_string(),
            body: body.to_vec(),
        }
    }

    // ── Tests ──────────────────────────────────────────────────────────────────

    #[allow(clippy::unwrap_used)]
    #[test]
    fn decrypt_ok_never_logs_plaintext() {
        const PT: &[u8] = b"known plaintext";
        let attester = FakeAttester;
        let kms = FakeKms {
            plaintext: PT.to_vec(),
        };
        let mut log = Vec::new();
        let (status, _, body) = handle(&put_decrypt(b"ciphertext"), &attester, &kms, &mut log);
        let log_str = String::from_utf8(log).unwrap();
        assert_eq!(status, 200);
        assert!(
            !log_str.contains("known plaintext"),
            "plaintext in log: {log_str}"
        );
        assert!(
            !log_str.contains("plaintext="),
            "plaintext field in log: {log_str}"
        );
        assert!(
            log_str.contains(&format!("decrypted sha256={}", sha256_hex(PT))),
            "missing sha256 line: {log_str}"
        );
        assert!(
            !body.contains("known plaintext"),
            "plaintext leaked into response: {body}"
        );
    }

    #[test]
    fn get_readings_returns_four_keys() {
        let req = http::Request {
            method: "GET".to_string(),
            path: "/readings".to_string(),
            body: Vec::new(),
        };
        let mut log = Vec::new();
        let (status, _, body) = handle(&req, &FakeAttester, &DeniedKms, &mut log);
        assert_eq!(status, 200);
        for k in [
            "\"kernel\":",
            "\"uptime_s\":",
            "\"disks\":",
            "\"dmi_product\":",
        ] {
            assert!(body.contains(k), "missing {k} in {body}");
        }
    }

    #[test]
    fn readings_json_escapes() {
        let s = readings_json(&[("kernel", "a\"b".to_string())]);
        assert_eq!(s, r#"{"kernel":"a\"b"}"#);
    }

    #[test]
    fn decrypt_denied_is_403_with_code() {
        let mut log = Vec::<u8>::new();
        let kms = ErrKms {
            code: "AccessDeniedException",
            message: "",
            denied: true,
        };
        let (status, _, body) = handle(&put_decrypt(b"fake_ct"), &FakeAttester, &kms, &mut log);
        assert_eq!(status, 403, "body: {body}");
        assert!(body.contains("kms-denied"), "body: {body}");
        assert!(body.contains("AccessDeniedException"), "body: {body}");
        let log_str = String::from_utf8_lossy(&log);
        assert!(
            log_str.contains("kms-denied code=AccessDeniedException"),
            "log: {log_str}"
        );
        assert!(
            !log_str.contains("plaintext="),
            "plaintext in log: {log_str}"
        );
    }

    #[test]
    fn kms_error_502_logs_code_and_message() {
        let mut log = Vec::<u8>::new();
        let kms = ErrKms {
            code: "InvalidCiphertextException",
            message: "ciphertext corrupt",
            denied: false,
        };
        let (status, _, body) = handle(&put_decrypt(b"fake_ct"), &FakeAttester, &kms, &mut log);
        assert_eq!(status, 502, "body: {body}");
        assert!(body.contains("kms-error"), "body: {body}");
        let log_str = String::from_utf8_lossy(&log);
        assert!(
            log_str.contains("kms-error code=InvalidCiphertextException"),
            "log: {log_str}"
        );
        assert!(
            log_str.contains("message=ciphertext corrupt"),
            "log: {log_str}"
        );
    }

    #[test]
    fn no_nsm_is_503_with_diagnostics() {
        let mut log = Vec::<u8>::new();
        let kms = ErrKms {
            code: "X",
            message: "",
            denied: false,
        };
        let attester = FailAttester("nsm broken".to_string());
        let (status, _, body) = handle(&put_decrypt(b"fake_ct"), &attester, &kms, &mut log);
        assert_eq!(status, 503, "body: {body}");
        assert!(body.contains("no-nsm"), "body: {body}");
        assert!(body.contains("nsm broken"), "body: {body}");
        // The diagnostics are JSON-escaped; no raw newlines may appear in the body.
        assert!(!body.contains('\n'), "raw newline in 503 body: {body}");
    }

    #[test]
    fn empty_body_is_400() {
        let mut log = Vec::<u8>::new();
        let kms = ErrKms {
            code: "X",
            message: "",
            denied: false,
        };
        let req = http::Request {
            method: "PUT".to_string(),
            path: "/decrypt".to_string(),
            body: vec![],
        };
        let (status, _, body) = handle(&req, &FakeAttester, &kms, &mut log);
        assert_eq!(status, 400, "body: {body}");
        assert!(body.contains("bad-input"), "body: {body}");
    }

    #[test]
    fn unknown_path_is_404() {
        let mut log = Vec::<u8>::new();
        let kms = ErrKms {
            code: "X",
            message: "",
            denied: false,
        };
        let req = http::Request {
            method: "GET".to_string(),
            path: "/unknown".to_string(),
            body: vec![],
        };
        let (status, _, _) = handle(&req, &FakeAttester, &kms, &mut log);
        assert_eq!(status, 404);
    }

    #[test]
    fn oversized_is_400() {
        let mut log = Vec::<u8>::new();
        let kms = ErrKms {
            code: "X",
            message: "",
            denied: false,
        };
        let req = http::Request {
            method: "PUT".to_string(),
            path: "/decrypt".to_string(),
            body: vec![0u8; 6145],
        };
        let (status, _, body) = handle(&req, &FakeAttester, &kms, &mut log);
        assert_eq!(status, 400, "body: {body}");
        assert!(body.contains("bad-input"), "body: {body}");
    }
}
