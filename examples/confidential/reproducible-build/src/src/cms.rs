//! Unwraps the `CiphertextForRecipient` that KMS Decrypt returns when the request carries a
//! `Recipient` (an attestation document holding our public key):
//! https://docs.aws.amazon.com/kms/latest/APIReference/API_Decrypt.html
//!
//! It is a CMS (RFC 5652) `ContentInfo` holding `EnvelopedData`, with one
//! `KeyTransRecipientInfo` whose content key is encrypted with RSAES-OAEP SHA-256, the only
//! `KeyEncryptionAlgorithm` the API reference allows, and AES-256-CBC content with the IV as
//! the algorithm parameter (RFC 3565). Neither the API reference nor the Nitro Enclaves
//! *Cryptographic attestation* page
//! (https://docs.aws.amazon.com/enclaves/latest/user/set-up-attestation.html) states the CMS
//! layout; the AWS Nitro Enclaves SDK's own parser does, in `source/cms.c` of
//! https://github.com/aws/aws-nitro-enclaves-sdk-c. That parser also accepts BER, so this one
//! decodes with BER rules too.

use ::cms::content_info::ContentInfo;
use ::cms::der::asn1::OctetString;
use ::cms::der::oid::db::rfc5911::{ID_AES_256_CBC, ID_ENVELOPED_DATA};
use ::cms::der::oid::db::rfc5912::ID_RSAES_OAEP;
use ::cms::der::{Decode, EncodingRules};
use ::cms::enveloped_data::{EnvelopedData, RecipientInfo};
use aes::Aes256;
use cbc::cipher::{BlockModeDecrypt, KeyIvInit, block_padding::Pkcs7};
use rsa::pkcs8::EncodePublicKey;
use rsa::sha2::Sha256;

pub struct RecipientKey {
    private: rsa::PrivateKey,
}

impl RecipientKey {
    pub fn generate() -> Result<Self, String> {
        let private = rsa::PrivateKey::new(&mut getrandom::SysRng, 2048)
            .map_err(|_| "generate RSA key failed")?;
        Ok(Self { private })
    }

    /// SubjectPublicKeyInfo DER, for the attestation document's `public_key`.
    pub fn public_key_der(&self) -> Result<Vec<u8>, String> {
        let doc = self
            .private
            .to_public_key()
            .to_public_key_der()
            .map_err(|_| "encode public key failed")?;
        Ok(doc.as_bytes().to_vec())
    }

    pub fn unwrap(&self, ciphertext: &[u8]) -> Result<Vec<u8>, String> {
        let info = ContentInfo::from_ber(ciphertext).map_err(|_| "decode ContentInfo failed")?;
        if info.content_type != ID_ENVELOPED_DATA {
            return Err("ContentInfo is not EnvelopedData".into());
        }
        let env: EnvelopedData = info
            .content
            .decode_as_encoding(EncodingRules::Ber)
            .map_err(|_| "decode EnvelopedData failed")?;
        let Some(RecipientInfo::Ktri(ktri)) = env.recip_infos.0.iter().next() else {
            return Err("no KeyTransRecipientInfo".into());
        };
        if ktri.key_enc_alg.oid != ID_RSAES_OAEP {
            return Err("key encryption is not RSAES-OAEP".into());
        }
        let cek = self
            .private
            .oaep_decrypt::<Sha256>(ktri.enc_key.as_bytes())
            .map_err(|_| "decrypt content key failed")?;
        if cek.len() != 32 {
            return Err("content key is not 32 bytes".into());
        }
        let eci = &env.encrypted_content;
        if eci.content_enc_alg.oid != ID_AES_256_CBC {
            return Err("content cipher is not AES-256-CBC".into());
        }
        let iv: OctetString = eci
            .content_enc_alg
            .parameters
            .as_ref()
            .ok_or("missing IV")?
            .decode_as()
            .map_err(|_| "decode IV failed")?;
        let content = eci.encrypted_content.as_ref().ok_or("missing content")?;
        cbc::Decryptor::<Aes256>::new_from_slices(&cek, iv.as_bytes())
            .map_err(|_| "IV is not 16 bytes")?
            .decrypt_padded_vec::<Pkcs7>(content.as_bytes())
            .map_err(|_| "decrypt content failed".into())
    }
}

/// Test support: build a KMS-shaped CMS encrypted to a SubjectPublicKeyInfo DER.
/// Used by FakeKms in main.rs tests; lives outside `mod tests` so other test modules can reach it.
#[cfg(test)]
pub(crate) mod test_support {
    use super::*;
    use ::cms::cert::x509::ext::pkix::SubjectKeyIdentifier;
    use ::cms::content_info::CmsVersion;
    use ::cms::der::oid::db::rfc5911::ID_DATA;
    use ::cms::der::{Any, Encode, Tag};
    use ::cms::enveloped_data::{
        EncryptedContentInfo, KeyTransRecipientInfo, RecipientIdentifier, RecipientInfos,
    };
    use ::cms::spki::AlgorithmIdentifierOwned;
    use cbc::cipher::BlockModeEncrypt;
    use rsa::pkcs8::DecodePublicKey;

    /// Return a ContentInfo DER holding EnvelopedData (RSAES-OAEP SHA-256 + AES-256-CBC)
    /// whose content key is encrypted to the given SPKI DER public key.
    #[allow(clippy::unwrap_used)]
    pub(crate) fn kms_shaped_cms(pub_key_der: &[u8], plaintext: &[u8]) -> Vec<u8> {
        let pub_key = rsa::PublicKey::from_public_key_der(pub_key_der).unwrap();
        let (cek, iv) = ([7u8; 32], [9u8; 16]);
        let enc_key = pub_key.oaep_encrypt::<Sha256>(&cek).unwrap();
        let ct = cbc::Encryptor::<Aes256>::new(&cek.into(), &iv.into())
            .encrypt_padded_vec::<Pkcs7>(plaintext);
        let ktri = KeyTransRecipientInfo {
            version: CmsVersion::V2,
            rid: RecipientIdentifier::SubjectKeyIdentifier(SubjectKeyIdentifier(
                OctetString::new(vec![1]).unwrap(),
            )),
            key_enc_alg: AlgorithmIdentifierOwned {
                oid: ID_RSAES_OAEP,
                parameters: None,
            },
            enc_key: OctetString::new(enc_key).unwrap(),
        };
        let env = EnvelopedData {
            version: CmsVersion::V2,
            originator_info: None,
            recip_infos: RecipientInfos::try_from(vec![RecipientInfo::Ktri(ktri)]).unwrap(),
            encrypted_content: EncryptedContentInfo {
                content_type: ID_DATA,
                content_enc_alg: AlgorithmIdentifierOwned {
                    oid: ID_AES_256_CBC,
                    parameters: Some(Any::new(Tag::OctetString, iv.to_vec()).unwrap()),
                },
                encrypted_content: Some(OctetString::new(ct).unwrap()),
            },
            unprotected_attrs: None,
        };
        ContentInfo {
            content_type: ID_ENVELOPED_DATA,
            content: Any::encode_from(&env).unwrap(),
        }
        .to_der()
        .unwrap()
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used)] // a test should fail loudly on any error
mod tests {
    use super::*;
    use ::cms::cert::x509::ext::pkix::SubjectKeyIdentifier;
    use ::cms::content_info::CmsVersion;
    use ::cms::der::oid::ObjectIdentifier;
    use ::cms::der::oid::db::rfc5911::ID_DATA;
    use ::cms::der::oid::db::rfc5912::RSA_ENCRYPTION;
    use ::cms::der::{Any, Encode, Tag};
    use ::cms::enveloped_data::{
        EncryptedContentInfo, KeyTransRecipientInfo, RecipientIdentifier, RecipientInfos,
    };
    use ::cms::spki::AlgorithmIdentifierOwned;
    use cbc::cipher::BlockModeEncrypt;

    const PLAINTEXT: &[u8] = b"known plaintext";

    /// The `EnvelopedData` KMS returns, built by hand: `cms::builder` encrypts the content key
    /// with RSAES-PKCS1-v1_5 only, so it cannot produce the RSAES-OAEP SHA-256 KMS uses.
    fn kms_shaped(key: &RecipientKey) -> (EnvelopedData, Vec<u8>) {
        kms_shaped_with(key, ID_RSAES_OAEP)
    }

    fn kms_shaped_with(
        key: &RecipientKey,
        key_enc_oid: ObjectIdentifier,
    ) -> (EnvelopedData, Vec<u8>) {
        let (cek, iv) = ([7u8; 32], [9u8; 16]);
        let enc_key = key
            .private
            .to_public_key()
            .oaep_encrypt::<Sha256>(&cek)
            .unwrap();
        let ct = cbc::Encryptor::<Aes256>::new(&cek.into(), &iv.into())
            .encrypt_padded_vec::<Pkcs7>(PLAINTEXT);
        let ktri = KeyTransRecipientInfo {
            version: CmsVersion::V2,
            rid: RecipientIdentifier::SubjectKeyIdentifier(SubjectKeyIdentifier(
                OctetString::new(vec![1]).unwrap(),
            )),
            // parameters: None here; KMS may encode the SHA-256/MGF1 parameters explicitly.
            key_enc_alg: AlgorithmIdentifierOwned {
                oid: key_enc_oid,
                parameters: None,
            },
            enc_key: OctetString::new(enc_key).unwrap(),
        };
        let env = EnvelopedData {
            version: CmsVersion::V2,
            originator_info: None,
            recip_infos: RecipientInfos::try_from(vec![RecipientInfo::Ktri(ktri)]).unwrap(),
            encrypted_content: EncryptedContentInfo {
                content_type: ID_DATA,
                content_enc_alg: AlgorithmIdentifierOwned {
                    oid: ID_AES_256_CBC,
                    parameters: Some(Any::new(Tag::OctetString, iv.to_vec()).unwrap()),
                },
                encrypted_content: Some(OctetString::new(ct.clone()).unwrap()),
            },
            unprotected_attrs: None,
        };
        (env, ct)
    }

    fn to_der(env: &EnvelopedData) -> Vec<u8> {
        ContentInfo {
            content_type: ID_ENVELOPED_DATA,
            content: Any::encode_from(env).unwrap(),
        }
        .to_der()
        .unwrap()
    }

    /// Indefinite-length BER, with the ciphertext split into a constructed OCTET STRING.
    fn to_ber(env: &EnvelopedData, ct: &[u8]) -> Vec<u8> {
        let ind =
            |tag: u8, parts: &[Vec<u8>]| [&[tag, 0x80][..], &parts.concat(), &[0, 0]].concat();
        let eci = &env.encrypted_content;
        let (a, b) = ct.split_at(5);
        let chunks = [
            OctetString::new(a).unwrap().to_der().unwrap(),
            OctetString::new(b).unwrap().to_der().unwrap(),
        ];
        let eci_ber = ind(
            0x30,
            &[
                eci.content_type.to_der().unwrap(),
                eci.content_enc_alg.to_der().unwrap(),
                ind(0xa0, &chunks),
            ],
        );
        let env_ber = ind(
            0x30,
            &[
                env.version.to_der().unwrap(),
                env.recip_infos.to_der().unwrap(),
                eci_ber,
            ],
        );
        ind(
            0x30,
            &[ID_ENVELOPED_DATA.to_der().unwrap(), ind(0xa0, &[env_ber])],
        )
    }

    #[test]
    fn unwraps_locally_built_enveloped_data() {
        let key = RecipientKey::generate().unwrap();
        let (env, _) = kms_shaped(&key);
        assert_eq!(key.unwrap(&to_der(&env)).unwrap(), PLAINTEXT);
    }

    #[test]
    fn unwraps_indefinite_length_ber() {
        let key = RecipientKey::generate().unwrap();
        let (env, ct) = kms_shaped(&key);
        let ber = to_ber(&env, &ct);
        assert_eq!(&ber[..2], &[0x30, 0x80]);
        assert_eq!(key.unwrap(&ber).unwrap(), PLAINTEXT);
    }

    #[test]
    fn rejects_wrong_key() {
        let (key, other) = (
            RecipientKey::generate().unwrap(),
            RecipientKey::generate().unwrap(),
        );
        let (env, _) = kms_shaped(&key);
        assert!(other.unwrap(&to_der(&env)).is_err());
    }

    #[test]
    fn rejects_non_oaep_key_encryption() {
        let key = RecipientKey::generate().unwrap();
        let (env, _) = kms_shaped_with(&key, RSA_ENCRYPTION);
        assert_eq!(
            key.unwrap(&to_der(&env)).unwrap_err(),
            "key encryption is not RSAES-OAEP"
        );
    }

    #[test]
    fn rejects_garbage() {
        let key = RecipientKey::generate().unwrap();
        assert!(key.unwrap(b"\x30\x00").is_err());
    }

    #[test]
    fn public_key_is_spki_der() {
        let key = RecipientKey::generate().unwrap();
        let der = key.public_key_der().unwrap();
        assert!(::cms::spki::SubjectPublicKeyInfoRef::from_der(&der).is_ok());
    }
}
