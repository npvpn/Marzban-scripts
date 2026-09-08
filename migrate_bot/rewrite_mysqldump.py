#!/usr/bin/env python3
"""Rewrite mysqldump --complete-insert to dest column intersection.

Keeps fork schema (extra dest columns stay DEFAULT/NULL). Drops source-only
columns that the current panel no longer has.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

INSERT_WITH_COLS = re.compile(
    r"^INSERT INTO `(?P<table>[^`]+)` \((?P<cols>.+)\) VALUES \((?P<values>.*)\)\s*;\s*$"
)
INSERT_NO_COLS = re.compile(
    r"^INSERT INTO `(?P<table>[^`]+)` VALUES \((?P<values>.*)\)\s*;\s*$"
)


def parse_col_list(raw: str) -> list[str]:
    cols = []
    for part in raw.split(","):
        name = part.strip().strip("`").strip()
        if name:
            cols.append(name)
    return cols


def split_sql_tuple(payload: str) -> list[str]:
    items: list[str] = []
    buf: list[str] = []
    in_str = False
    i = 0
    n = len(payload)
    while i < n:
        ch = payload[i]
        if in_str:
            buf.append(ch)
            if ch == "\\":
                if i + 1 < n:
                    buf.append(payload[i + 1])
                    i += 2
                    continue
            elif ch == "'":
                if i + 1 < n and payload[i + 1] == "'":
                    buf.append(payload[i + 1])
                    i += 2
                    continue
                in_str = False
            i += 1
            continue
        if ch == "'":
            in_str = True
            buf.append(ch)
            i += 1
            continue
        if ch == ",":
            items.append("".join(buf).strip())
            buf = []
            i += 1
            continue
        buf.append(ch)
        i += 1
    if buf:
        items.append("".join(buf).strip())
    return items


def quote_ident(name: str) -> str:
    return f"`{name}`"


def rewrite_insert(
    table: str,
    cols: list[str],
    values: list[str],
    dest_cols: dict[str, list[str]],
) -> str | None:
    dest = dest_cols.get(table)
    if dest is None:
        dest = dest_cols.get("*")
    if dest is None:
        return None
    dest_set = set(dest)
    keep_idx = [i for i, col in enumerate(cols) if col in dest_set]
    if not keep_idx:
        return None
    if len(values) != len(cols):
        raise ValueError(
            f"column/value count mismatch for {table}: {len(cols)} cols vs {len(values)} values"
        )
    new_cols = [cols[i] for i in keep_idx]
    new_vals = [values[i] for i in keep_idx]
    return (
        f"INSERT INTO `{table}` ({', '.join(quote_ident(c) for c in new_cols)}) "
        f"VALUES ({', '.join(new_vals)});"
    )


def load_cols(path: Path) -> dict[str, list[str]]:
    if not path or not path.is_file():
        return {}
    raw = json.loads(path.read_text(encoding="utf-8"))
    return {str(k): [str(x) for x in v] for k, v in raw.items()}


INSERT_TABLE_NAME = re.compile(r"^INSERT INTO `([^`]+)`")


def rewrite_dump(
    src: Path,
    dest_cols: dict[str, list[str]],
    source_cols: dict[str, list[str]],
    out: Path,
    skip_tables: set[str] | None = None,
) -> dict:
    skip = skip_tables or set()
    stats = {
        "rewritten": 0,
        "passthrough": 0,
        "skipped_no_overlap": 0,
        "skipped_table": 0,
        "tables": {},
    }
    with src.open("r", encoding="utf-8", errors="replace") as fh, out.open("w", encoding="utf-8") as out_fh:
        for line_no, raw in enumerate(fh, start=1):
            line = raw.rstrip("\n")
            stripped = line.strip()
            if not stripped.startswith("INSERT INTO"):
                out_fh.write(raw if raw.endswith("\n") else raw + "\n")
                stats["passthrough"] += 1
                continue
            table_match = INSERT_TABLE_NAME.match(stripped)
            table_guess = table_match.group(1) if table_match else ""
            if table_guess in skip:
                stats["skipped_table"] += 1
                continue
            match = INSERT_WITH_COLS.match(stripped)
            cols: list[str] | None = None
            table = ""
            values_raw = ""
            if match:
                table = match.group("table")
                cols = parse_col_list(match.group("cols"))
                values_raw = match.group("values")
            else:
                match = INSERT_NO_COLS.match(stripped)
                if not match:
                    raise ValueError(f"unrecognized INSERT at line {line_no}: {stripped[:180]}")
                table = match.group("table")
                cols = source_cols.get(table)
                if not cols:
                    raise ValueError(
                        f"INSERT without column names for `{table}` at line {line_no}, "
                        "and source column list is missing"
                    )
                values_raw = match.group("values")
            values = split_sql_tuple(values_raw)
            rewritten = rewrite_insert(table, cols, values, dest_cols)
            if rewritten is None:
                stats["skipped_no_overlap"] += 1
                continue
            out_fh.write(rewritten + "\n")
            stats["rewritten"] += 1
            stats["tables"][table] = stats["tables"].get(table, 0) + 1
    return stats


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("dump_sql")
    parser.add_argument("dest_columns_json")
    parser.add_argument("out_sql")
    parser.add_argument("--source-columns-json", default="")
    parser.add_argument(
        "--skip-tables",
        default="",
        help="Comma-separated table names: skip INSERT lines without parsing values",
    )
    args = parser.parse_args()
    dest_cols = load_cols(Path(args.dest_columns_json))
    source_cols = load_cols(Path(args.source_columns_json)) if args.source_columns_json else {}
    skip_tables = {name.strip() for name in args.skip_tables.split(",") if name.strip()}
    stats = rewrite_dump(
        Path(args.dump_sql),
        dest_cols,
        source_cols,
        Path(args.out_sql),
        skip_tables=skip_tables,
    )
    json.dump(stats, sys.stdout, ensure_ascii=False, indent=2)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
