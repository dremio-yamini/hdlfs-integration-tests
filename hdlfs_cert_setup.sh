#!/usr/bin/env bash
# hdlfs_cert_setup.sh — Certificate lifecycle helper for HDLFS mTLS
#
# MODE=new-client   Generate a new private key + CSR (run on the target machine)
# MODE=sign-csr     Sign a CSR with the local CA (run on the SAP laptop)
# MODE=verify       Verify the cert chain (run on either machine)
#
# Required env vars per mode:
#   new-client:  CERT_DIR, CN
#   sign-csr:    CERT_DIR, CN, CSR_FILE
#   verify:      CERT_DIR

set -euo pipefail

MODE="${MODE:?Set MODE=new-client|sign-csr|verify}"
CERT_DIR="${CERT_DIR:?Set CERT_DIR=./certs}"
mkdir -p "${CERT_DIR}"

case "${MODE}" in

  new-client)
    CN="${CN:?Set CN=<common-name> e.g. dremio-laptop}"
    KEY="${CERT_DIR}/${CN}.key"
    CSR="${CERT_DIR}/${CN}.csr"

    echo "Generating private key: ${KEY}"
    openssl genrsa -out "${KEY}" 2048
    chmod 600 "${KEY}"

    echo "Generating CSR: ${CSR}"
    openssl req -new -key "${KEY}" -out "${CSR}" -subj "/CN=${CN}"

    echo ""
    echo "=== CSR (send this to the SAP laptop for signing) ==="
    cat "${CSR}"
    echo ""
    echo "Private key stays on THIS machine: ${KEY}"
    echo "Next step on SAP laptop: MODE=sign-csr CERT_DIR=./certs CN=${CN} CSR_FILE=<path-to-csr> bash hdlfs_cert_setup.sh"
    ;;

  sign-csr)
    CN="${CN:?Set CN=<common-name>}"
    CSR_FILE="${CSR_FILE:?Set CSR_FILE=<path-to-csr>}"
    CA_KEY="${CERT_DIR}/ca.key"
    CA_CRT="${CERT_DIR}/ca.crt"
    OUT_CRT="${CERT_DIR}/client-${CN}.crt"

    [[ -f "${CA_KEY}" ]] || { echo "CA key not found: ${CA_KEY}"; exit 1; }
    [[ -f "${CA_CRT}" ]] || { echo "CA cert not found: ${CA_CRT}"; exit 1; }
    [[ -f "${CSR_FILE}" ]] || { echo "CSR not found: ${CSR_FILE}"; exit 1; }

    echo "Signing CSR with CA..."
    openssl x509 -req -days 3650 \
        -in "${CSR_FILE}" \
        -CA "${CA_CRT}" -CAkey "${CA_KEY}" -CAcreateserial \
        -out "${OUT_CRT}"

    echo ""
    echo "=== Signed certificate (send this back — not secret) ==="
    cat "${OUT_CRT}"
    echo ""
    echo "Signed cert saved: ${OUT_CRT}"
    echo "CA cert for trust: ${CA_CRT}"
    ;;

  verify)
    CA_CRT="${CERT_DIR}/ca.crt"
    [[ -f "${CA_CRT}" ]] || { echo "CA cert not found: ${CA_CRT}"; exit 1; }

    echo "=== CA cert ==="
    openssl x509 -in "${CA_CRT}" -noout -subject -dates

    echo ""
    for crt in "${CERT_DIR}"/*.crt; do
        [[ "${crt}" == "${CA_CRT}" ]] && continue
        echo "=== ${crt} ==="
        openssl x509 -in "${crt}" -noout -subject -dates
        openssl verify -CAfile "${CA_CRT}" "${crt}" && echo "Chain: OK" || echo "Chain: FAILED"
        echo ""
    done
    ;;

  *)
    echo "Unknown MODE: ${MODE}. Use new-client, sign-csr, or verify."
    exit 1
    ;;
esac
