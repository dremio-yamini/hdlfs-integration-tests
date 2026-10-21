# HDLFS Integration Tests

Tools, scripts, and documentation for connecting to **SAP HANA Data Lake Files (HDLFS)** from Dremio using mutual TLS (mTLS).

HDLFS is SAP's cloud file storage service built on the WebHDFS REST API. Access is secured via **mTLS** — both client and server present certificates during the TLS handshake. There are no username/password credentials; authentication is entirely certificate-based.

---

## Contents

| File | Description |
|------|-------------|
| [`DREMIO_HDLFS_CONNECT.md`](DREMIO_HDLFS_CONNECT.md) | Full step-by-step connection guide (start here) |
| [`hdlfs.sh`](hdlfs.sh) | Bash shell library — list, upload, download, append, delete |
| [`hdlfs_client.py`](hdlfs_client.py) | Python client with smoke test |
| [`hdlfs_cert_setup.sh`](hdlfs_cert_setup.sh) | Certificate lifecycle helper (generate key/CSR, sign, verify) |
| [`ca.crt`](ca.crt) | CA certificate used to sign client certs |
| [`certs/`](certs/) | Sample client certificate and CSR (no private keys) |

---

## Architecture

```
Dremio laptop / executor
  ├── private key          (never leaves this machine)
  ├── client cert          (signed by SAP's CA)
  └── CA cert              (provided by SAP)
          │
          │  mTLS (port 443)
          ▼
HDLFS endpoint: https://<uuid>.files.hdl.<region>.hanacloud.ondemand.com
  └── WebHDFS REST API  (/webhdfs/v1/...)
```

**Key points:**
- The private key is generated locally and never shared
- The CSR (certificate signing request) is sent to SAP — it contains only the public key, no secrets
- SAP signs the CSR and returns a `.crt` file
- SAP must also authorize the client CN in HANA Cloud Central before access is granted

---

## Prerequisites

| Requirement | Details |
|-------------|---------|
| HDLFS instance | Provisioned via SAP HANA Cloud Central on BTP |
| SAP-side contact | Someone with admin access to the HDLFS instance |
| Outbound HTTPS | Port 443 to `*.hdl.<region>.hanacloud.ondemand.com` |
| Tools | `openssl`, `curl`, `python3` + `pip install requests` |

> **BTP setup note:** The HDLFS service key contains only the host and port — there are no username/password credentials. If you hit a 422 OIDC trust error in HANA Cloud Central, it means the trust is only configured at the global account level. Business apps like HANA Cloud Central need a separate trust established **at the subaccount level**.

---

## Quick Start — Shell

```bash
# 1. Generate your private key and CSR
MODE=new-client CERT_DIR=./certs CN=dremio-laptop bash hdlfs_cert_setup.sh
#    → prints the CSR — send it to the SAP team for signing

# 2. Save the signed cert returned by SAP
cat > ./certs/client-dremio-laptop.crt << 'CERT'
-----BEGIN CERTIFICATE-----
<paste signed certificate here>
-----END CERTIFICATE-----
CERT

# 3. Convert key to PKCS#8 (required by curl)
openssl pkcs8 -topk8 -nocrypt \
  -in ./certs/dremio-laptop.key \
  -out ./certs/dremio-laptop-pkcs8.key

# 4. Export env vars
export HDLFS_ENDPOINT="https://<uuid>.files.hdl.<region>.hanacloud.ondemand.com"
export HDLFS_CONTAINER="<uuid>"
export HDLFS_CERT="./certs/client-dremio-laptop.crt"
export HDLFS_KEY="./certs/dremio-laptop-pkcs8.key"
export HDLFS_CACERT="skip"   # skip SAP server cert verification (acceptable for testing)

# 5. Verify connectivity
source hdlfs.sh && hdlfs_check
```

Expected output:
```
Endpoint  : https://<uuid>.files.hdl.<region>.hanacloud.ondemand.com
Container : <uuid>
Cert      : ./certs/client-dremio-laptop.crt
Key       : ./certs/dremio-laptop-pkcs8.key
CA cert   : skip

Live LISTSTATUS / ... OK — N entries at /
```

### Common shell operations

```bash
source hdlfs.sh

hdlfs_ls /                                      # list root
hdlfs_upload ./local-file.csv /remote/file.csv  # upload
hdlfs_download /remote/file.csv ./copy.csv      # download
hdlfs_cat /remote/file.csv                      # print to stdout
hdlfs_append ./more.csv /remote/file.csv        # append
hdlfs_delete /remote/file.csv                   # delete file
hdlfs_rmdir /remote/folder                      # delete directory (recursive)
```

---

## Quick Start — Python

```bash
pip install requests
```

```python
from hdlfs_client import HdlfsClient

# Reads HDLFS_ENDPOINT, HDLFS_CONTAINER, HDLFS_CERT_PATH, HDLFS_KEY_PATH from env
# (same vars as the shell client, plus HDLFS_CERT_PATH / HDLFS_KEY_PATH)
with HdlfsClient() as c:
    c.check()                                      # connectivity diagnostics

    c.upload_text("hello\n", "/test/hello.txt")    # upload text
    print(c.read_text("/test/hello.txt"))           # download and read
    c.append_text("world\n", "/test/hello.txt")    # append

    for entry in c.ls("/"):                        # list directory
        print(entry["pathSuffix"], entry["type"])

    c.delete("/test/hello.txt")                    # delete
```

Run the built-in smoke test (upload → read → append → list → delete):
```bash
python3 hdlfs_client.py
```

---

## Supported WebHDFS Operations

| Operation | WebHDFS op | Shell | Python |
|-----------|-----------|-------|--------|
| List directory | `LISTSTATUS` | `hdlfs_ls` | `c.ls()` |
| Upload file | `CREATE` | `hdlfs_upload` | `c.upload()` / `c.upload_text()` |
| Download file | `OPEN` | `hdlfs_download` | `c.download()` / `c.read_text()` |
| Read byte range | `OPEN` + offset/length | `hdlfs_read_range` | `c.read_range()` |
| Append to file | `APPEND` | `hdlfs_append` | `c.append()` / `c.append_text()` |
| Delete file/dir | `DELETE` | `hdlfs_delete` / `hdlfs_rmdir` | `c.delete()` / `c.rmdir()` |

**Not supported by HDLFS:** `MKDIRS`, `RENAME`, `GETFILESTATUS`, `GETACL`, `SETACL`

> Directories are created implicitly when uploading a file — no explicit `mkdir` needed.

---

## SAP-Side Setup (HANA Cloud Central)

After the SAP team signs your CSR, they must authorize your client CN in HANA Cloud Central:

1. HANA Cloud Central → Data Lake Files instance → **Actions → Manage Configuration**
2. **Data Lake Files → Trusts** → upload `ca.crt`, name the trust group (e.g. `dremio-ca`)
3. **Data Lake Files → Authorizations** → add:
   - **Pattern**: `CN=dremio-laptop`
   - **Rank**: `1`
   - **Roles**: `user`
   - **Trust Bindings**: `dremio-ca`
4. Save

Without this step, all requests return `403 does not have enough privileges`.

---

## SGW Temporary Credentials (S3/GCS path) — Currently Blocked

HDLFS can vend temporary S3/GCS credentials via:
```
POST /webhdfs/v1/?op=GENERATETEMPORARYCREDENTIALS
```

This requires **`CFC_DIRECT_ACCESS_ENABLED=true`** to be set on the HDLFS cluster — it is a cluster-level flag controlled by the SAP HANA Cloud ops team, not a per-instance setting in HANA Cloud Central.

On `prod-eu12` this is currently **not enabled**. Contact the SAP HANA Cloud ops team to enable it on a landscape.

---

## Troubleshooting

| Error | Cause | Fix |
|-------|-------|-----|
| `HDLFS_CERT: parameter not set` | Env vars not exported | Re-run the `export` commands |
| `unable to set private key file` | PKCS#1 key format | Convert with `openssl pkcs8 -topk8 -nocrypt` (Step 3 above) |
| `SSL certificate problem: unable to get local issuer certificate` | `ca.crt` is the client CA, not SAP's server CA | Set `HDLFS_CACERT=skip` |
| `403 does not have enough privileges` | Client CN not authorized | SAP team must add the CN authorization in HANA Cloud Central |
| `400 Bad Request` on upload | Wrong `Content-Type` | Always use `Content-Type: application/octet-stream` for uploads |
| `500 too many error responses` on `MKDIRS` | Operation not supported | Don't call mkdir — HDLFS creates dirs implicitly on upload |
| `GENERATETEMPORARYCREDENTIALS not supported` | Direct Access not enabled | Contact SAP HANA Cloud ops to enable `CFC_DIRECT_ACCESS_ENABLED` |
| 422 OIDC trust error in HANA Cloud Central | Trust only at global account level | Add a separate trust at the **subaccount** level in BTP |

---

## Security

- Private keys (`*.key`) are excluded from this repository via `.gitignore`
- Generate your own key/CSR with `hdlfs_cert_setup.sh` — the private key never leaves your machine
- `HDLFS_CACERT=skip` disables server certificate verification and is acceptable for testing; in production, obtain SAP's server CA and pass it via `HDLFS_CACERT`
