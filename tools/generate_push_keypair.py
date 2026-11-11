# -*- coding: utf-8 -*-
"""Generate an RSA key pair for the Huawei service-account credential.

The AGC "创建服务账号凭证" form asks for a public key (raw Base64 DER,
without PEM headers). This script generates a 4096-bit RSA key pair and:

  private/huawei-push-private.pem   <- keep secret, used to sign JWT
  private/huawei-push-public.b64    <- paste into AGC "公钥"

Usage:
    python tools/generate_push_keypair.py
"""
from __future__ import annotations

import base64
from pathlib import Path

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa

OUT = Path(__file__).resolve().parents[1] / "private"


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    private_path = OUT / "huawei-push-private.pem"
    public_path = OUT / "huawei-push-public.b64"
    if private_path.exists() or public_path.exists():
        print("Key pair already exists. Back it up before generating a replacement.")
        return 1

    key = rsa.generate_private_key(public_exponent=65537, key_size=4096)

    private_pem = key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    )
    public_der = key.public_key().public_bytes(
        encoding=serialization.Encoding.DER,
        format=serialization.PublicFormat.SubjectPublicKeyInfo,
    )
    public_b64 = base64.b64encode(public_der).decode("ascii")

    private_path.write_bytes(private_pem)
    public_path.write_text(public_b64 + "\n", encoding="ascii")

    print("=" * 72)
    print("RSA 4096 key pair generated")
    print(f"Private key : {private_path}")
    print(f"Public key  : {public_path}")
    print("=" * 72)
    print("Copy the single Base64 line below into the AGC public-key field:")
    print()
    print(public_b64)
    print()
    print("Do NOT paste the private key anywhere.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
