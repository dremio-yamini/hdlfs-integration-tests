# Connecting to SAP BTP HANA Data Lake Files (HDLFS) from Dremio

## Overview

HDLFS is SAP's cloud file storage service built on the WebHDFS REST API. Access is secured using **mutual TLS (mTLS)** — both the client and server present certificates during the TLS handshake. This guide walks through everything needed to connect a Dremio laptop to an HDLFS instance hosted on SAP BTP.

---

## Prerequisites

| Requirement | Details |
|-------------|---------|
| HDLFS instance | Created via SAP HANA Cloud Central on BTP |
| SAP-side contact | Someone with admin access to the HDLFS instance and HANA Cloud Central |
| Outbound HTTPS | Port 443 to `*.hdl.<region>.hanacloud.ondemand.com` — no VPN needed for `prod-eu12` |
| Tools | `openssl`, `curl`, `python3`, `pip3` |

---

## Step 1 — Install prerequisites on the Dremio laptop

```bash
# macOS
brew install openssl curl python3

# Linux
apt-get install openssl curl python3 python3-pip

pip3 install requests
```

---

## Step 2 — Get files from the SAP team

Ask the SAP-side contact to share these files (none are secret):

| File | Purpose |
|------|---------|
| `hdlfs.sh` | Shell operation library |
| `hdlfs_client.py` | Python client |
| `hdlfs_cert_setup.sh` | Certificate lifecycle helper |
| `ca.crt` | CA certificate used to sign client certs |

**Do NOT request** `ca.key`, `client.key`, or `client.crt` from the SAP side.

---

## Step 3 — Generate a private key and CSR on the Dremio laptop

The private key is generated here and **never leaves this machine**.

```bash
mkdir -p ./certs
cp ca.crt ./certs/

MODE=new-client CERT_DIR=./certs CN=dremio-laptop bash hdlfs_cert_setup.sh
```

This prints a CSR. Send it to the SAP-side contact (it is not sensitive).

---

## Step 4 — Get the signed certificate back from SAP

The SAP-side contact signs the CSR and sends back a `.crt` file. Save it:

```bash
cat > ./certs/client-dremio-laptop.crt << 'EOF'
-----BEGIN CERTIFICATE-----
<paste signed certificate here>
-----END CERTIFICATE-----
EOF
```

---

## Step 5 — Convert the private key to PKCS#8 format

curl requires PKCS#8 format (`BEGIN PRIVATE KEY`). If the generated key is PKCS#1 (`BEGIN RSA PRIVATE KEY`), convert it:

```bash
# Check format
head -1 ./certs/dremio-laptop.key

# If it shows BEGIN RSA PRIVATE KEY, convert:
openssl pkcs8 -topk8 -nocrypt -in ./certs/dremio-laptop.key -out ./certs/dremio-laptop-pkcs8.key

# Use the pkcs8 key going forward
```

---

## Step 6 — SAP team: authorize the new certificate in HANA Cloud Central

The SAP-side contact must authorize the new client CN in HANA Cloud Central:

1. HANA Cloud Central → Data Lake Files instance → **Actions → Manage Configuration**
2. **Data Lake Files → Trusts** → upload `ca.crt`, name the trust group (e.g. `test-ca`)
3. **Data Lake Files → Authorizations** → add:
   - **Pattern**: `CN=dremio-laptop`
   - **Rank**: `1`
   - **Roles**: `user`
   - **Trust Bindings**: `test-ca`
4. Save

---

## Step 7 — Set environment variables

```bash
export HDLFS_ENDPOINT="https://<uuid>.files.hdl.<region>.hanacloud.ondemand.com"
export HDLFS_CONTAINER="<uuid>"
export HDLFS_CERT="./certs/client-dremio-laptop.crt"
export HDLFS_KEY="./certs/dremio-laptop-pkcs8.key"
export HDLFS_CERT_PATH="./certs/client-dremio-laptop.crt"
export HDLFS_KEY_PATH="./certs/dremio-laptop-pkcs8.key"
export HDLFS_CACERT="skip"
```

> `HDLFS_CACERT=skip` disables server certificate verification. This is acceptable for testing since the server uses SAP's DigiCert-issued certificate which the system truststore may not include.

---

## Step 8 — Verify connectivity

```bash
# Shell check
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

---

## Step 9 — Run the Python smoke test

```bash
python3 hdlfs_client.py
```

Expected output:
```
Endpoint  : https://<uuid>.files.hdl.<region>.hanacloud.ondemand.com
Container : <uuid>
Cert      : ./certs/client-dremio-laptop.crt  (OK)
Key       : ./certs/dremio-laptop-pkcs8.key  (OK)
CA verify : False
ls /      : OK — N entries
Smoke test: all OK ✓
```

---

## Supported WebHDFS Operations

| Operation | WebHDFS op | Notes |
|-----------|-----------|-------|
| List directory | `LISTSTATUS` | |
| Upload file | `CREATE` | Must use `Content-Type: application/octet-stream` |
| Download file | `OPEN` | |
| Append to file | `APPEND` | |
| Delete file/dir | `DELETE` | Pass `recursive=true` for directories |

**Not supported by HDLFS:** `MKDIRS`, `RENAME`, `GETFILESTATUS`, `GETACL`, `SETACL`

> Directories are created implicitly when uploading a file — no explicit `mkdir` needed.

---

## Troubleshooting

| Error | Cause | Fix |
|-------|-------|-----|
| `HDLFS_CERT: parameter not set` | Env vars not exported | Run the `export` commands in Step 7 |
| `--cacert: unknown option` | Old `hdlfs.sh` version | Get the latest `hdlfs.sh` from the SAP team |
| `unable to set private key file` | Wrong key file or PKCS#1 format | Convert key with `openssl pkcs8` (Step 5) |
| `SSL certificate problem: unable to get local issuer certificate` | `ca.crt` is the client CA, not SAP's server CA | Set `HDLFS_CACERT=skip` |
| `403 does not have enough privileges` | Client CN not authorized | SAP team must add authorization in HANA Cloud Central (Step 6) |
| `500 too many error responses` on `MKDIRS` | Operation not supported | Don't use `mkdir` — HDLFS creates dirs implicitly |
| `GENERATETEMPORARYCREDENTIALS not supported` | Direct Access not enabled on cluster | Contact SAP HANA Cloud team to enable `CFC_DIRECT_ACCESS_ENABLED` on the landscape |

---

## HDLFS Instance Details (for reference)

| Field | Value |
|-------|-------|
| Endpoint | `https://<uuid>.files.hdl.<region>.hanacloud.ondemand.com` |
| Container (CFC UUID) | `<uuid>` (same as the subdomain prefix) |
| SGW files URL | `https://<uuid>.files.hdl.<region>.hanacloud.ondemand.com` |
| SGW sharing URL | `https://<uuid>.sharing.hdl.<region>.hanacloud.ondemand.com` |
| Auth protocol | mTLS (client certificate + private key) |

---

## Notes on SGW Temporary Credentials (Dremio/S3 path)

HDLFS can vend temporary S3/GCS credentials via:
```
POST /webhdfs/v1/?op=GENERATETEMPORARYCREDENTIALS
```

This requires **Direct Access** to be enabled on the HDLFS cluster (`CFC_DIRECT_ACCESS_ENABLED=true`), which is a server-side flag set by the SAP HANA Cloud operations team — not configurable per instance in HANA Cloud Central. Contact the SAP team to confirm which landscape has this enabled.
