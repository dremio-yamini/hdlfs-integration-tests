#!/usr/bin/env bash
# hdlfs.sh — HDLFS WebHDFS shell operation library
# Usage: source hdlfs.sh && hdlfs_check

set -euo pipefail

# ── Required env vars ────────────────────────────────────────────────────────
# HDLFS_ENDPOINT   https://<uuid>.files.hdl.<region>.hanacloud.ondemand.com
# HDLFS_CONTAINER  <uuid>
# HDLFS_CERT       path to client.crt
# HDLFS_KEY        path to client.key
# HDLFS_CACERT     path to ca.crt, or "skip" for --insecure (dev only)

_hdlfs_curl() {
    local cacert_args=()
    if [[ "${HDLFS_CACERT:-}" == "skip" ]]; then
        cacert_args=("--insecure")
    elif [[ -n "${HDLFS_CACERT:-}" ]]; then
        cacert_args=("--cacert" "${HDLFS_CACERT}")
    fi
    curl --silent --fail-with-body \
        --cert  "${HDLFS_CERT}" \
        --key   "${HDLFS_KEY}" \
        "${cacert_args[@]}" \
        -H "x-sap-filecontainer: ${HDLFS_CONTAINER}" \
        "$@"
}

_hdlfs_url() {
    local path="${1:-/}"
    [[ "${path}" == /* ]] || path="/${path}"
    echo "${HDLFS_ENDPOINT}/webhdfs/v1${path}"
}

# ── Diagnostics ──────────────────────────────────────────────────────────────
hdlfs_check() {
    echo "Endpoint  : ${HDLFS_ENDPOINT:-<not set>}"
    echo "Container : ${HDLFS_CONTAINER:-<not set>}"
    echo "Cert      : ${HDLFS_CERT:-<not set>}"
    echo "Key       : ${HDLFS_KEY:-<not set>}"
    echo "CA cert   : ${HDLFS_CACERT:-<not set>}"
    echo ""
    echo -n "Live LISTSTATUS / ... "
    _hdlfs_curl "$(_hdlfs_url /)?op=LISTSTATUS" | python3 -c "
import sys, json
d = json.load(sys.stdin)
n = len(d.get('FileStatuses', {}).get('FileStatus', []))
print(f'OK — {n} entries at /')
" && return 0 || echo "FAILED"
}

# ── Directory operations ─────────────────────────────────────────────────────
hdlfs_ls() {
    local path="${1:-/}"
    _hdlfs_curl "$(_hdlfs_url "${path}")?op=LISTSTATUS" | python3 -c "
import sys, json
for e in json.load(sys.stdin)['FileStatuses']['FileStatus']:
    t = 'd' if e['type']=='DIRECTORY' else '-'
    print(f\"{t}  {e['length']:>12}  {e['pathSuffix']}\")
"
}

hdlfs_stat() {
    local path="${1:?Usage: hdlfs_stat <path>}"
    _hdlfs_curl "$(_hdlfs_url "${path}")?op=GETFILESTATUS" | python3 -m json.tool
}

hdlfs_mkdir() {
    local path="${1:?Usage: hdlfs_mkdir <path>}"
    _hdlfs_curl -X PUT "$(_hdlfs_url "${path}")?op=MKDIRS" | python3 -c "
import sys, json; print('OK' if json.load(sys.stdin).get('boolean') else 'FAILED')
"
}

hdlfs_exists() {
    local path="${1:?Usage: hdlfs_exists <path>}"
    local code
    local cacert_args=()
    if [[ "${HDLFS_CACERT:-}" == "skip" ]]; then
        cacert_args=("--insecure")
    elif [[ -n "${HDLFS_CACERT:-}" ]]; then
        cacert_args=("--cacert" "${HDLFS_CACERT}")
    fi
    code=$(curl --silent --output /dev/null --write-out "%{http_code}" \
        --cert "${HDLFS_CERT}" --key "${HDLFS_KEY}" \
        "${cacert_args[@]}" \
        -H "x-sap-filecontainer: ${HDLFS_CONTAINER}" \
        "$(_hdlfs_url "${path}")?op=GETFILESTATUS")
    case "${code}" in
        200) echo "exists";    return 0 ;;
        404) echo "not found"; return 1 ;;
        *)   echo "error ${code}"; return 2 ;;
    esac
}

hdlfs_tree() {
    local path="${1:-/}"
    _hdlfs_curl "$(_hdlfs_url "${path}")?op=LISTSTATUS" | python3 -c "
import sys, json

def tree(entries, prefix=''):
    for i, e in enumerate(entries):
        connector = '└── ' if i == len(entries)-1 else '├── '
        suffix = '/' if e['type']=='DIRECTORY' else ''
        print(f\"{prefix}{connector}{e['pathSuffix']}{suffix}\")

d = json.load(sys.stdin)
entries = d.get('FileStatuses', {}).get('FileStatus', [])
print('${path}')
tree(entries)
"
}

# ── Upload ───────────────────────────────────────────────────────────────────
hdlfs_upload() {
    local local_path="${1:?Usage: hdlfs_upload <local> <remote> [overwrite]}"
    local remote_path="${2:?}"
    local overwrite="${3:-false}"
    _hdlfs_curl -X PUT \
        -H "Content-Type: application/octet-stream" \
        --data-binary "@${local_path}" \
        "$(_hdlfs_url "${remote_path}")?op=CREATE&overwrite=${overwrite}"
    echo "Uploaded ${local_path} → ${remote_path}"
}

hdlfs_upload_text() {
    local text="${1:?Usage: hdlfs_upload_text <text> <remote>}"
    local remote_path="${2:?}"
    _hdlfs_curl -X PUT \
        -H "Content-Type: application/octet-stream" \
        --data-binary "${text}" \
        "$(_hdlfs_url "${remote_path}")?op=CREATE&overwrite=true"
    echo "Uploaded text → ${remote_path}"
}

# ── Download / read ──────────────────────────────────────────────────────────
hdlfs_download() {
    local remote_path="${1:?Usage: hdlfs_download <remote> <local>}"
    local local_path="${2:?}"
    _hdlfs_curl "$(_hdlfs_url "${remote_path}")?op=OPEN" --output "${local_path}"
    echo "Downloaded ${remote_path} → ${local_path}"
}

hdlfs_cat() {
    local remote_path="${1:?Usage: hdlfs_cat <remote>}"
    _hdlfs_curl "$(_hdlfs_url "${remote_path}")?op=OPEN"
}

hdlfs_read_range() {
    local remote_path="${1:?Usage: hdlfs_read_range <remote> <offset> <len>}"
    local offset="${2:?}"
    local length="${3:?}"
    _hdlfs_curl "$(_hdlfs_url "${remote_path}")?op=OPEN&offset=${offset}&length=${length}"
}

# ── Append ───────────────────────────────────────────────────────────────────
hdlfs_append() {
    local local_path="${1:?Usage: hdlfs_append <local> <remote>}"
    local remote_path="${2:?}"
    _hdlfs_curl -X POST \
        -H "Content-Type: application/octet-stream" \
        --data-binary "@${local_path}" \
        "$(_hdlfs_url "${remote_path}")?op=APPEND"
    echo "Appended ${local_path} → ${remote_path}"
}

hdlfs_append_text() {
    local text="${1:?Usage: hdlfs_append_text <text> <remote>}"
    local remote_path="${2:?}"
    _hdlfs_curl -X POST \
        -H "Content-Type: application/octet-stream" \
        --data-binary "${text}" \
        "$(_hdlfs_url "${remote_path}")?op=APPEND"
    echo "Appended text → ${remote_path}"
}

# ── Rename / delete ──────────────────────────────────────────────────────────
hdlfs_rename() {
    local src="${1:?Usage: hdlfs_rename <src> <dst>}"
    local dst="${2:?}"
    _hdlfs_curl -X PUT \
        "$(_hdlfs_url "${src}")?op=RENAME&destination=${dst}" | python3 -c "
import sys, json; print('OK' if json.load(sys.stdin).get('boolean') else 'FAILED')
"
}

hdlfs_delete() {
    local path="${1:?Usage: hdlfs_delete <path> [recursive]}"
    local recursive="${2:-false}"
    _hdlfs_curl -X DELETE \
        "$(_hdlfs_url "${path}")?op=DELETE&recursive=${recursive}" | python3 -c "
import sys, json; print('OK' if json.load(sys.stdin).get('boolean') else 'FAILED')
"
}

hdlfs_rmdir() {
    local path="${1:?Usage: hdlfs_rmdir <path>}"
    hdlfs_delete "${path}" true
}
