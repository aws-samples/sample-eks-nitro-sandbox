"""A minimal OpenPGP signer for the offline tests only: an RSA test key made per run, its armored
public key, and binary detached signatures in the shape HashiCorp publishes (SHA256SUMS.sig).

It exists because gpg on some workstations ships without gpg-agent, and gpg2 cannot make a key or
a signature without the agent, while `gpg --verify` (what the sample's tool check runs) needs no
agent. The packets follow RFC 4880: a version 4 RSA public key, a user ID with a positive
certification, and version 4 signatures with SHA-256. The private key never leaves the process
memory and is never written to disk.
"""
import base64
import hashlib
import struct
import time

from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import padding, rsa, utils

CREATED = int(time.time()) - 60


def _len(n):
    if n < 192:
        return bytes([n])
    if n < 8384:
        n -= 192
        return bytes([(n >> 8) + 192, n & 0xFF])
    return b"\xff" + struct.pack(">I", n)


def _packet(tag, body):
    return bytes([0xC0 | tag]) + _len(len(body)) + body


def _mpi(i):
    b = i.to_bytes((i.bit_length() + 7) // 8, "big")
    return struct.pack(">H", i.bit_length()) + b


def _sub(t, data):
    return _len(len(data) + 1) + bytes([t]) + data


def _crc24(data):
    crc = 0xB704CE
    for byte in data:
        crc ^= byte << 16
        for _ in range(8):
            crc <<= 1
            if crc & 0x1000000:
                crc ^= 0x1864CFB
    return crc & 0xFFFFFF


def _armor(kind, data):
    b64 = base64.b64encode(data).decode()
    lines = "\n".join(b64[i:i + 64] for i in range(0, len(b64), 64))
    crc = base64.b64encode(_crc24(data).to_bytes(3, "big")).decode()
    return f"-----BEGIN PGP {kind}-----\n\n{lines}\n={crc}\n-----END PGP {kind}-----\n".encode()


class Key:
    def __init__(self, uid):
        self.priv = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        pub = self.priv.public_key().public_numbers()
        self.body = b"\x04" + struct.pack(">I", CREATED) + b"\x01" + _mpi(pub.n) + _mpi(pub.e)
        # The version 4 fingerprint is SHA-1 by definition (RFC 4880 section 12.2): an identifier
        # that gpg prints and compares, not a security use of the hash.
        self.fpr = hashlib.sha1(b"\x99" + struct.pack(">H", len(self.body)) + self.body, usedforsecurity=False).digest()
        self.uid = uid.encode()

    @property
    def fingerprint(self):
        return self.fpr.hex().upper()

    def _sig(self, sigtype, prefix):
        hashed = (_sub(2, struct.pack(">I", CREATED)) + _sub(33, b"\x04" + self.fpr)
                  + (_sub(27, b"\x03") if sigtype == 0x13 else b""))
        head = bytes([4, sigtype, 1, 8]) + struct.pack(">H", len(hashed)) + hashed
        digest = hashlib.sha256(prefix + head + b"\x04\xff" + struct.pack(">I", len(head))).digest()
        sig = self.priv.sign(digest, padding.PKCS1v15(), utils.Prehashed(hashes.SHA256()))
        unhashed = _sub(16, self.fpr[-8:])
        body = head + struct.pack(">H", len(unhashed)) + unhashed + digest[:2] + _mpi(int.from_bytes(sig, "big"))
        return _packet(2, body)

    def public_armored(self):
        key_prefix = b"\x99" + struct.pack(">H", len(self.body)) + self.body
        uid_prefix = b"\xb4" + struct.pack(">I", len(self.uid)) + self.uid
        data = _packet(6, self.body) + _packet(13, self.uid) + self._sig(0x13, key_prefix + uid_prefix)
        return _armor("PUBLIC KEY BLOCK", data)

    def sign_detached(self, data):
        return self._sig(0x00, data)
