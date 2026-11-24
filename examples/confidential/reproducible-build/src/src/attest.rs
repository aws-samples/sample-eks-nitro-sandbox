use aws_nitro_enclaves_nsm_api::{
    api::{Request, Response},
    driver::{nsm_exit, nsm_init, nsm_process_request},
};
use ciborium::Value;
use serde_bytes::ByteBuf;
use std::fmt::Write as _;
use std::fs;
use std::path::Path;

pub trait Attester {
    fn attest(&self, public_key_der: &[u8]) -> Result<Vec<u8>, String>;
}

pub struct Nsm;

struct NsmDescriptor(i32);

impl Drop for NsmDescriptor {
    fn drop(&mut self) {
        nsm_exit(self.0);
    }
}

impl Attester for Nsm {
    fn attest(&self, public_key_der: &[u8]) -> Result<Vec<u8>, String> {
        let fd = nsm_init();
        if fd < 0 {
            return Err("could not open /dev/nsm".to_string());
        }
        let descriptor = NsmDescriptor(fd);
        let response = nsm_process_request(
            descriptor.0,
            Request::Attestation {
                public_key: Some(ByteBuf::from(public_key_der.to_vec())),
                user_data: None,
                nonce: None,
            },
        );
        match response {
            Response::Attestation { document } => Ok(document),
            Response::Error(e) => Err(format!("NSM returned {e:?}")),
            other => Err(format!("NSM returned unexpected response: {other:?}")),
        }
    }
}

/// Extract the payload bytes from a COSE_Sign1 attestation document.
#[allow(dead_code)] // available for a validator binary; not called in the decrypt binary
///
/// Handles both tagged (`0xd2`) and untagged CBOR arrays.
pub fn cose_payload(document: &[u8]) -> Result<Vec<u8>, String> {
    let mut encoded = document;
    let value: Value = ciborium::from_reader(&mut encoded)
        .map_err(|error| format!("invalid COSE_Sign1 CBOR: {error}"))?;
    if !encoded.is_empty() {
        return Err(format!("COSE_Sign1 has {} trailing bytes", encoded.len()));
    }
    let sign1 = match value {
        Value::Tag(18, tagged) => *tagged,
        Value::Tag(tag, _) => {
            return Err(format!(
                "attestation document has unexpected CBOR tag {tag}"
            ));
        }
        untagged => untagged,
    };
    let Value::Array(mut fields) = sign1 else {
        return Err("COSE_Sign1 value is not an array".to_string());
    };
    if fields.len() != 4 {
        return Err(format!(
            "COSE_Sign1 array has {} fields instead of 4",
            fields.len()
        ));
    }
    match fields.swap_remove(2) {
        Value::Bytes(payload) => Ok(payload),
        _ => Err("COSE_Sign1 payload is not a byte string".to_string()),
    }
}

fn path_state(path: &Path) -> String {
    match fs::metadata(path) {
        Ok(_) => "present".to_string(),
        Err(error) => format!("unavailable: {error}"),
    }
}

fn virtio_devices() -> String {
    let devices_path = Path::new("/sys/bus/virtio/devices");
    let entries = match fs::read_dir(devices_path) {
        Ok(entries) => entries,
        Err(error) => return format!("  unavailable: {error}\n"),
    };
    let mut device_paths = entries
        .filter_map(Result::ok)
        .map(|entry| entry.path())
        .collect::<Vec<_>>();
    device_paths.sort();

    if device_paths.is_empty() {
        return "  none\n".to_string();
    }

    let mut diagnostics = String::new();
    for device_path in device_paths {
        let name = device_path
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("unknown");
        let device_id = fs::read_to_string(device_path.join("device"))
            .map(|value| value.trim().to_string())
            .unwrap_or_else(|error| format!("unreadable ({error})"));
        let driver = fs::read_link(device_path.join("driver"))
            .ok()
            .and_then(|path| path.file_name().map(|name| name.to_owned()))
            .and_then(|name| name.into_string().ok())
            .unwrap_or_else(|| "unbound".to_string());
        let _ = writeln!(diagnostics, "  {name}: device={device_id}, driver={driver}");
    }
    diagnostics
}

pub fn nsm_diagnostics() -> String {
    format!(
        "Guest NSM diagnostics:\n\
         /dev/nsm: {}\n\
         NSM virtio driver: {}\n\
         virtio-MMIO transport driver: {}\n\
         virtio devices:\n{}",
        path_state(Path::new("/dev/nsm")),
        path_state(Path::new("/sys/bus/virtio/drivers/nsm")),
        path_state(Path::new("/sys/bus/platform/drivers/virtio-mmio")),
        virtio_devices()
    )
}

#[cfg(test)]
mod tests {
    use super::{cose_payload, nsm_diagnostics};

    #[test]
    fn extracts_payload_from_tagged_cose_sign1() {
        let encoded = [0xd2, 0x84, 0x40, 0xa0, 0x42, b'h', b'i', 0x40];
        assert_eq!(cose_payload(&encoded), Ok(b"hi".to_vec()));
    }

    #[test]
    fn extracts_payload_from_untagged_cose_sign1() {
        let encoded = [0x84, 0x40, 0xa0, 0x42, b'h', b'i', 0x40];
        assert_eq!(cose_payload(&encoded), Ok(b"hi".to_vec()));
    }

    #[test]
    fn rejects_unexpected_cbor_tag() {
        let encoded = [0xd3, 0x84, 0x40, 0xa0, 0x42, b'h', b'i', 0x40];
        assert_eq!(
            cose_payload(&encoded),
            Err("attestation document has unexpected CBOR tag 19".to_string())
        );
    }

    #[test]
    fn diagnostics_list_nsm_path() {
        let diag = nsm_diagnostics();
        assert!(diag.contains("/dev/nsm:"));
        assert!(diag.contains("NSM virtio driver:"));
        assert!(diag.contains("virtio-MMIO transport driver:"));
        assert!(diag.contains("virtio devices:"));
    }
}
