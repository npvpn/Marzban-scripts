#!/usr/bin/env python3
"""Rename legacy bot files to the multibot layout `{bot_id}__{name}`.

Source (single-tenant):  src/files/start.sub_is_active.png
Platform (multibot):     src/files/29__start.sub_is_active.png
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import sys
import tarfile
import tempfile
from pathlib import Path

PREFIX_RE = re.compile(r"^\d+__")
SKIP_NAMES = {".", "..", "SHA256SUMS", ".gitignore", ".gitkeep", "Thumbs.db"}


def prefixed_filename(name: str, bot_id: int | str) -> str:
    base = Path(str(name or "")).name
    if not base or base in SKIP_NAMES or base.startswith("."):
        return ""
    base = PREFIX_RE.sub("", base)
    return f"{int(bot_id)}__{base}"


def _files_root(src_dir: Path) -> Path:
    nested = src_dir / "files"
    if nested.is_dir():
        return nested
    return src_dir


def iter_source_files(src_dir: Path) -> list[Path]:
    root = _files_root(src_dir)
    if not root.is_dir():
        return []
    files: list[Path] = []
    for path in sorted(root.iterdir()):
        if not path.is_file():
            continue
        if path.name in SKIP_NAMES or path.name.startswith("."):
            continue
        files.append(path)
    return files


def copy_prefixed(src_dir: Path, dest_dir: Path, bot_id: int | str) -> list[dict]:
    dest_dir.mkdir(parents=True, exist_ok=True)
    manifest: list[dict] = []
    for src in iter_source_files(src_dir):
        dest_name = prefixed_filename(src.name, bot_id)
        if not dest_name:
            continue
        dest = dest_dir / dest_name
        shutil.copy2(src, dest)
        manifest.append({"src": src.name, "dest": dest_name, "bytes": src.stat().st_size})
    return manifest


def extract_tgz(archive: Path, dest_dir: Path) -> None:
    dest_dir.mkdir(parents=True, exist_ok=True)
    if not archive.is_file() or archive.stat().st_size == 0:
        return
    with tarfile.open(archive, "r:gz") as tar:
        try:
            tar.extractall(dest_dir, filter="data")
        except TypeError:
            tar.extractall(dest_dir)


def write_tgz(src_dir: Path, archive: Path) -> int:
    files = [p for p in src_dir.iterdir() if p.is_file()] if src_dir.is_dir() else []
    if not files:
        return 0
    archive.parent.mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive, "w:gz") as tar:
        for path in sorted(files):
            tar.add(path, arcname=path.name)
    return len(files)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bot-id", required=True)
    parser.add_argument("--src-dir", default="")
    parser.add_argument("--src-tgz", default="")
    parser.add_argument("--dest-dir", default="")
    parser.add_argument("--dest-tgz", default="")
    parser.add_argument("--manifest", default="")
    args = parser.parse_args()

    tmp: tempfile.TemporaryDirectory[str] | None = None
    src_dir = Path(args.src_dir) if args.src_dir else None
    if args.src_tgz:
        tmp = tempfile.TemporaryDirectory(prefix="migrate_bot_files_")
        src_dir = Path(tmp.name)
        extract_tgz(Path(args.src_tgz), src_dir)
    if src_dir is None:
        print("Need --src-dir or --src-tgz", file=sys.stderr)
        return 2

    dest_holder: tempfile.TemporaryDirectory[str] | None = None
    dest_dir = Path(args.dest_dir) if args.dest_dir else None
    if dest_dir is None:
        dest_holder = tempfile.TemporaryDirectory(prefix="migrate_bot_files_out_")
        dest_dir = Path(dest_holder.name)

    try:
        manifest = copy_prefixed(src_dir, dest_dir, args.bot_id)
        packed = 0
        if args.dest_tgz:
            packed = write_tgz(dest_dir, Path(args.dest_tgz))
        if args.manifest:
            Path(args.manifest).write_text(
                json.dumps({"bot_id": int(args.bot_id), "files": manifest, "count": len(manifest)}, ensure_ascii=False, indent=2)
                + "\n",
                encoding="utf-8",
            )
        print(json.dumps({"count": len(manifest), "packed": packed}, ensure_ascii=False))
    finally:
        if tmp is not None:
            tmp.cleanup()
        if dest_holder is not None:
            dest_holder.cleanup()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
