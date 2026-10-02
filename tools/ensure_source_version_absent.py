#!/usr/bin/env python3
"""Fail closed when source.json already has the version being promoted."""

import json
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 3:
        print("Usage: ensure_source_version_absent.py VERSION SOURCE_JSON", file=sys.stderr)
        return 2

    version, source_path = sys.argv[1], Path(sys.argv[2])
    try:
        with source_path.open(encoding="utf-8") as source_file:
            source = json.load(source_file)
        versions = source["apps"][0]["versions"]
        if not isinstance(versions, list):
            raise TypeError("apps[0].versions must be a list")
        version_exists = any(entry.get("version") == version for entry in versions)
    except (OSError, json.JSONDecodeError, KeyError, IndexError, TypeError, AttributeError) as error:
        print(f"Unable to safely inspect {source_path}: {error}", file=sys.stderr)
        return 2

    if version_exists:
        print(
            f"source.json already contains {version} before production promotion; "
            "refusing an ambiguous duplicate release.",
            file=sys.stderr,
        )
        return 1

    print(f"source.json does not contain {version}; source update may proceed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
