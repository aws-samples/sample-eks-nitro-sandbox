//! KMS Decrypt wrapper that asks KMS to encrypt the plaintext back to our ephemeral RSA key
//! via the Recipient mechanism so the result never appears on the wire in the clear.

use aws_config::BehaviorVersion;
use aws_sdk_kms::Client;
use aws_sdk_kms::error::DisplayErrorContext;
use aws_sdk_kms::primitives::Blob;
use aws_sdk_kms::types::{KeyEncryptionMechanism, RecipientInfo};

/// A KMS operation error.  `denied` is set for `AccessDeniedException` and for
/// `KMSInvalidStateException` when the message indicates the attestation was refused.
pub struct KmsError {
    pub code: String,
    pub message: String,
    pub denied: bool,
}

pub trait Kms {
    fn decrypt(&self, ciphertext: &[u8], attestation_doc: &[u8]) -> Result<Vec<u8>, KmsError>;
}

/// Production implementation: holds a single-thread tokio runtime and an SDK client.
pub struct SdkKms {
    rt: tokio::runtime::Runtime,
    client: Client,
}

impl SdkKms {
    pub fn new() -> Result<Self, String> {
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .map_err(|e| format!("tokio runtime: {e}"))?;
        let config = rt.block_on(aws_config::load_defaults(BehaviorVersion::latest()));
        let client = Client::new(&config);
        Ok(Self { rt, client })
    }
}

impl Kms for SdkKms {
    fn decrypt(&self, ciphertext: &[u8], attestation_doc: &[u8]) -> Result<Vec<u8>, KmsError> {
        let recipient = RecipientInfo::builder()
            .key_encryption_algorithm(KeyEncryptionMechanism::RsaesOaepSha256)
            .attestation_document(Blob::new(attestation_doc.to_vec()))
            .build();
        let result = self.rt.block_on(
            self.client
                .decrypt()
                .ciphertext_blob(Blob::new(ciphertext.to_vec()))
                .recipient(recipient)
                .send(),
        );
        match result {
            Ok(output) => output
                .ciphertext_for_recipient()
                .map(|b| b.as_ref().to_vec())
                .ok_or_else(|| KmsError {
                    code: "MissingCiphertextForRecipient".to_string(),
                    message: "CiphertextForRecipient absent in KMS response".to_string(),
                    denied: false,
                }),
            Err(err) => {
                let (code, message, denied) = match err.as_service_error() {
                    Some(svc) => {
                        let meta = svc.meta();
                        let code = meta.code().unwrap_or("Unknown").to_string();
                        let message = meta.message().unwrap_or("").to_string();
                        let denied = code == "AccessDeniedException"
                            || (code == "KMSInvalidStateException"
                                && message.to_ascii_lowercase().contains("attestation"));
                        (code, message, denied)
                    }
                    None => {
                        // No service-level code; derive a category from the display string
                        // (e.g. "timeout error: …" → "timeout_error"). The message carries the
                        // whole source chain: the top level alone ("dispatch failure") does not
                        // say whether DNS, TLS or the credential endpoint failed.
                        let msg = DisplayErrorContext(&err).to_string();
                        let code = msg
                            .split_once(':')
                            .map(|(k, _)| k.trim().replace(' ', "_"))
                            .unwrap_or_else(|| "SdkError".to_string());
                        (code, msg, false)
                    }
                };
                Err(KmsError {
                    code,
                    message,
                    denied,
                })
            }
        }
    }
}
