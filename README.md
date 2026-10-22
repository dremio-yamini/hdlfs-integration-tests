# HDLFS Integration Tests

Integration test scripts and tooling for connecting Dremio to **SAP HANA Data Lake Files (HDLFS)** via mutual TLS (mTLS).

## Contents

| File | Description |
|------|-------------|
| `DREMIO_HDLFS_CONNECT.md` | Step-by-step connection guide |
| `hdlfs.sh` | WebHDFS shell operation library |
| `hdlfs_client.py` | Python smoke-test client |
| `hdlfs_cert_setup.sh` | Certificate lifecycle helper |
| `ca.crt` | CA certificate for signing client certs |
| `certs/` | Sample client certificate and CSR (no private keys) |

## Quick Start

See [DREMIO_HDLFS_CONNECT.md](DREMIO_HDLFS_CONNECT.md) for the full setup walkthrough.

```bash
export HDLFS_ENDPOINT="https://<uuid>.files.hdl.<region>.hanacloud.ondemand.com"
export HDLFS_CONTAINER="<uuid>"
export HDLFS_CERT="./certs/client-dremio-laptop.crt"
export HDLFS_KEY="./certs/dremio-laptop-pkcs8.key"
export HDLFS_CACERT="skip"

source hdlfs.sh && hdlfs_check   # shell connectivity check
python3 hdlfs_client.py          # Python smoke test
```

## Architecture

HDLFS uses **mTLS** — there are no usernames or passwords. Authentication is entirely certificate-based: the client presents a certificate during the TLS handshake, and HDLFS validates it against a CA that the SAP team controls.

```
Dremio laptop / executor
  ├── private key        ← generated locally, never leaves this machine
  ├── client cert        ← CSR sent to SAP team → they sign it → returned as .crt
  └── CA cert            ← provided by SAP (used to verify the signed cert)
          │
          │  mTLS (HTTPS port 443)
          ▼
HDLFS  https://<uuid>.files.hdl.<region>.hanacloud.ondemand.com
  └── WebHDFS REST API (/webhdfs/v1/...)
          │
          ▼
   SAP HANA Cloud Central
     └── Authorizations: CN=dremio-laptop must be explicitly added here
         before any request is accepted (otherwise → 403)
```

**Certificate flow:**
1. Dremio generates a private key + CSR locally (`hdlfs_cert_setup.sh`)
2. CSR (public key only, not sensitive) is sent to the SAP team
3. SAP signs the CSR with their CA and returns a `.crt` file
4. SAP adds the client CN (e.g. `CN=dremio-laptop`) to the authorization list in HANA Cloud Central
5. Dremio uses the private key + signed cert for all subsequent requests

## Why SGW Temporary Credentials Don't Work

HDLFS can vend temporary S3/GCS credentials, which would allow Dremio to connect via the standard S3 path instead of WebHDFS:

```
POST /webhdfs/v1/?op=GENERATETEMPORARYCREDENTIALS
```

**This is currently blocked.** The operation requires `CFC_DIRECT_ACCESS_ENABLED=true` — a cluster-level flag on the SAP HANA Cloud landscape. It is **not** a per-instance setting and cannot be toggled in HANA Cloud Central.

On `prod-eu12` this flag is not enabled. The `/catalog/v2` and `/policies/v2` endpoints also return errors for the same reason.

To unblock: contact the SAP HANA Cloud ops team and request `CFC_DIRECT_ACCESS_ENABLED` be enabled on a landscape. Until then, the only supported path is **direct WebHDFS via mTLS** using these scripts.

## Security

Private keys (`*.key`) are excluded via `.gitignore` and were never committed.
