#!/usr/bin/env python3
"""Create a deterministic source archive; never include caches or credentials."""
import gzip
import hashlib
import io
import os
from pathlib import Path
import tarfile

ROOT = Path(__file__).resolve().parents[1]
FILES = {"Package.swift", "LICENSE", "README.md", "CHANGELOG.md", "RELEASE.md", ".gitignore", "SOURCE.json"}
PREFIXES = {"Sources", "Tests", "Examples", "scripts", "docs"}
SUFFIXES = {".swift", ".py", ".sh", ".md", ".sql"}


def members(root=ROOT):
    result = []
    for path in sorted(root.rglob("*")):
        relative = path.relative_to(root)
        if relative.parts[0] not in PREFIXES and str(relative) not in FILES:
            continue
        if any(part.startswith(".") or part in {"__pycache__", "node_modules"} for part in relative.parts[1:]):
            continue
        if path.is_symlink():
            raise ValueError("source archive refuses symbolic links")
        if path.is_file() and (str(relative) in FILES or path.suffix in SUFFIXES):
            result.append(path)
    if not {"Package.swift", "LICENSE", "README.md"}.issubset({str(p.relative_to(root)) for p in result}):
        raise ValueError("required SwiftPM source files missing")
    return result


def build(root=ROOT):
    output = root / ".build/artifacts/Stayo-0.1.0-source.tar.gz"
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("wb") as raw, gzip.GzipFile(fileobj=raw, mode="wb", filename="", mtime=0) as zipped:
        with tarfile.open(fileobj=zipped, mode="w") as archive:
            for path in members(root):
                name = str(path.relative_to(root))
                data = path.read_bytes()
                info = tarfile.TarInfo(name)
                info.size = len(data)
                info.mode = 0o755 if name in {"scripts/package.sh", "scripts/package.py"} else 0o644
                info.mtime = 0
                archive.addfile(info, io.BytesIO(data))
    output.with_suffix(output.suffix + ".sha256").write_text(hashlib.sha256(output.read_bytes()).hexdigest() + "  " + output.name + "\n")
    return output


if __name__ == "__main__":
    print(build())
