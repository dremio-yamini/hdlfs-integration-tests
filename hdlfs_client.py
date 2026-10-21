"""
hdlfs_client.py — HDLFS WebHDFS Python client
pip install requests
"""
from __future__ import annotations
import os, sys
from pathlib import Path
from typing import Generator, Optional, Tuple, Union

CertPair   = Tuple[str, str]
VerifyArg  = Union[str, bool]
RemotePath = str
LocalPath  = Union[str, Path]
FileStatus = dict


class HdlfsClient:
    def __init__(
        self,
        endpoint:  Optional[str]       = None,
        container: Optional[str]       = None,
        cert:      Optional[CertPair]  = None,
        cacert:    Optional[VerifyArg] = None,
        timeout:   int                 = 60,
    ) -> None:
        self.endpoint  = (endpoint  or os.environ["HDLFS_ENDPOINT"]).rstrip("/")
        self.container = container or os.environ["HDLFS_CONTAINER"]
        self.timeout   = timeout
        self._cert: CertPair = cert or (
            os.environ["HDLFS_CERT_PATH"],
            os.environ["HDLFS_KEY_PATH"],
        )
        if cacert is not None:
            self._verify: VerifyArg = cacert
        else:
            raw = os.environ.get("HDLFS_CACERT", "")
            self._verify = False if raw.lower() in ("false", "skip") else (raw or True)
        self._session = self._build_session()

    def _build_session(self):
        import requests
        from requests.adapters import HTTPAdapter
        from urllib3.util.retry import Retry
        s = requests.Session()
        s.cert, s.verify = self._cert, self._verify
        s.headers["x-sap-filecontainer"] = self.container
        s.mount("https://", HTTPAdapter(max_retries=Retry(
            total=3, backoff_factor=0.5,
            status_forcelist=[500, 502, 503, 504],
            allowed_methods=["GET", "PUT", "POST", "DELETE"],
        )))
        return s

    def _url(self, path):
        return f"{self.endpoint}/webhdfs/v1{path if path.startswith('/') else '/'+path}"

    def _get(self, p, q, **kw):  r = self._session.get(self._url(p),  params=q, timeout=self.timeout, **kw); r.raise_for_status(); return r
    def _put(self, p, q, **kw):  r = self._session.put(self._url(p),  params=q, timeout=self.timeout, **kw); r.raise_for_status(); return r
    def _post(self, p, q, **kw): r = self._session.post(self._url(p), params=q, timeout=self.timeout, **kw); r.raise_for_status(); return r
    def _del(self, p, q, **kw):  r = self._session.delete(self._url(p), params=q, timeout=self.timeout, **kw); r.raise_for_status(); return r

    # ── Directory ───────────────────────────────────────────────────────────
    def ls(self, path="/") -> list[FileStatus]:
        return self._get(path, {"op": "LISTSTATUS"}).json()["FileStatuses"]["FileStatus"]

    # ── Upload ──────────────────────────────────────────────────────────────
    def upload(self, local: LocalPath, remote: RemotePath, overwrite=False):
        with open(local, "rb") as f:
            self._put(remote, {"op": "CREATE", "overwrite": str(overwrite).lower()},
                      data=f, headers={"Content-Type": "application/octet-stream"})

    def upload_bytes(self, data: bytes, remote: RemotePath, overwrite=False):
        self._put(remote, {"op": "CREATE", "overwrite": str(overwrite).lower()},
                  data=data, headers={"Content-Type": "application/octet-stream"})

    def upload_text(self, text: str, remote: RemotePath, overwrite=False, enc="utf-8"):
        self.upload_bytes(text.encode(enc), remote, overwrite=overwrite)

    # ── Download / read ─────────────────────────────────────────────────────
    def download(self, remote: RemotePath, local: LocalPath, chunk=8<<20):
        Path(local).parent.mkdir(parents=True, exist_ok=True)
        r = self._get(remote, {"op": "OPEN"}, stream=True)
        with open(local, "wb") as f:
            for c in r.iter_content(chunk_size=chunk): f.write(c)

    def read_bytes(self, remote: RemotePath, offset=0, length: Optional[int]=None) -> bytes:
        p = {"op": "OPEN"}
        if offset: p["offset"] = offset
        if length is not None: p["length"] = length
        return self._get(remote, p).content

    def read_text(self, remote: RemotePath, enc="utf-8") -> str:
        return self.read_bytes(remote).decode(enc)

    def read_range(self, remote: RemotePath, offset: int, length: int) -> bytes:
        return self.read_bytes(remote, offset=offset, length=length)

    # ── Append ──────────────────────────────────────────────────────────────
    def append(self, local: LocalPath, remote: RemotePath):
        with open(local, "rb") as f:
            self._post(remote, {"op": "APPEND"}, data=f,
                       headers={"Content-Type": "application/octet-stream"})

    def append_bytes(self, data: bytes, remote: RemotePath):
        self._post(remote, {"op": "APPEND"}, data=data,
                   headers={"Content-Type": "application/octet-stream"})

    def append_text(self, text: str, remote: RemotePath, enc="utf-8"):
        self.append_bytes(text.encode(enc), remote)

    # ── Rename / delete ─────────────────────────────────────────────────────
    def delete(self, path: RemotePath, recursive=False) -> bool:
        return bool(self._del(path, {"op": "DELETE", "recursive": str(recursive).lower()}).json().get("boolean"))

    def rmdir(self, path: RemotePath) -> bool:
        return self.delete(path, recursive=True)

    # ── Walk ────────────────────────────────────────────────────────────────
    def walk(self, root="/") -> Generator:
        entries = self.ls(root)
        dirs  = [e for e in entries if e["type"] == "DIRECTORY"]
        files = [e for e in entries if e["type"] == "FILE"]
        yield root, dirs, files
        for d in dirs:
            yield from self.walk(root.rstrip("/") + "/" + d["pathSuffix"])

    # ── Diagnostics ─────────────────────────────────────────────────────────
    def check(self):
        print(f"Endpoint  : {self.endpoint}")
        print(f"Container : {self.container}")
        print(f"Cert      : {self._cert[0]}  ({'OK' if Path(self._cert[0]).is_file() else 'MISSING'})")
        print(f"Key       : {self._cert[1]}  ({'OK' if Path(self._cert[1]).is_file() else 'MISSING'})")
        print(f"CA verify : {self._verify}")
        try:
            entries = self.ls("/")
            print(f"ls /      : OK — {len(entries)} entries")
        except Exception as e:
            print(f"ls /      : FAILED — {e}")

    def __enter__(self): return self
    def __exit__(self, *_): self._session.close()


if __name__ == "__main__":
    import time
    c = HdlfsClient(); c.check()
    ts = int(time.time()); base = f"/smoke-{ts}"; f = f"{base}/probe.txt"

    # Upload
    c.upload_text(f"test@{ts}\n", f, overwrite=True)

    # Download and verify
    content = c.read_text(f)
    assert content == f"test@{ts}\n", f"read_text mismatch: {content!r}"

    # Append and verify
    c.append_text("line2\n", f)
    content = c.read_text(f)
    assert "line2" in content, f"append_text mismatch: {content!r}"

    # List and verify file appears
    entries = c.ls(base)
    names = [e["pathSuffix"] for e in entries]
    assert "probe.txt" in names, f"ls mismatch: {names}"

    # Delete and verify gone
    c.rmdir(base)
    entries = c.ls("/")
    names = [e["pathSuffix"] for e in entries]
    assert base.strip("/") not in names, f"delete mismatch: {names}"

    print("Smoke test: all OK ✓")