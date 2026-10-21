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
# Set required env vars
export HDLFS_ENDPOINT="https://<uuid>.files.hdl.<region>.hanacloud.ondemand.com"
export HDLFS_CONTAINER="<uuid>"
export HDLFS_CERT="./certs/client-dremio-laptop.crt"
export HDLFS_KEY="./certs/dremio-laptop-pkcs8.key"
export HDLFS_CACERT="skip"

# Shell connectivity check
source hdlfs.sh && hdlfs_check

# Python smoke test
python3 hdlfs_client.py
```

## Security
Generate your own key/CSR with `hdlfs_cert_setup.sh` — the private key never leaves your machine.
