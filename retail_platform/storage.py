"""Blob storage for images. Local disk now; an S3-compatible store implements the same API.

Keys are tenant-prefixed and content-addressed so a key never reveals outlet names
and identical uploads cannot overwrite different content.
"""

from __future__ import annotations

import hashlib
from pathlib import Path
from typing import Protocol


class BlobStore(Protocol):
    def put(self, key: str, data: bytes) -> None: ...
    def get(self, key: str) -> bytes: ...
    def exists(self, key: str) -> bool: ...


class LocalBlobStore:
    def __init__(self, root: Path) -> None:
        self.root = root
        self.root.mkdir(parents=True, exist_ok=True)

    def _path(self, key: str) -> Path:
        path = (self.root / key).resolve()
        if self.root.resolve() not in path.parents:
            raise ValueError("Invalid blob key")
        return path

    def put(self, key: str, data: bytes) -> None:
        path = self._path(key)
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(path.suffix + ".tmp")
        tmp.write_bytes(data)
        tmp.replace(path)

    def get(self, key: str) -> bytes:
        return self._path(key).read_bytes()

    def exists(self, key: str) -> bool:
        return self._path(key).is_file()


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def capture_key(organization_id: str, digest: str, extension: str) -> str:
    return f"{organization_id}/captures/{digest[:2]}/{digest}.{extension}"


def artifact_key(organization_id: str, inference_id: str) -> str:
    return f"{organization_id}/artifacts/{inference_id}.jpg"
