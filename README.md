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

`GENERATETEMPORARYCREDENTIALS` (which would allow Dremio to connect via S3 instead of WebHDFS) requires `CFC_DIRECT_ACCESS_ENABLED=true` — a **cluster-level flag** set by the SAP HANA Cloud ops team, not configurable per instance. This is not enabled on `prod-eu12`. Contact the SAP HANA Cloud ops team to enable it on a landscape.

## Security

Private keys (`*.key`) are excluded via `.gitignore` and were never committed.
