#!/usr/bin/env python3
"""Verify and unpack an exact RouteLocation feature-CI artifact for promotion.

This performs no build, signing, publishing, or source metadata update.
"""

from __future__ import annotations

import argparse
import hashlib
import io
import json
from pathlib import Path
import plistlib
import re
import zipfile


INFO_PLIST_PATH = "Payload/RouteLocation.app/Info.plist"


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def normalize_digest(value: str | None) -> str | None:
    if not value:
        return None
    return value.removeprefix("sha256:").lower()


def inspect_ipa(data: bytes, *, version: str, build: str, bundle_id: str, min_os: str) -> dict:
    try:
        with zipfile.ZipFile(io.BytesIO(data)) as ipa:
            if INFO_PLIST_PATH not in ipa.namelist():
                raise ValueError(f"IPA is missing {INFO_PLIST_PATH}")
            plist = plistlib.loads(ipa.read(INFO_PLIST_PATH))
    except (zipfile.BadZipFile, plistlib.InvalidFileException) as error:
        raise ValueError(f"Invalid IPA: {error}") from error

    actual = {
        "bundleIdentifier": plist.get("CFBundleIdentifier"),
        "version": plist.get("CFBundleShortVersionString"),
        "build": str(plist.get("CFBundleVersion", "")),
        "minOSVersion": str(plist.get("MinimumOSVersion", "")),
    }
    expected = {
        "bundleIdentifier": bundle_id,
        "version": version,
        "build": build,
        "minOSVersion": min_os,
    }
    if actual != expected:
        raise ValueError(f"IPA Info.plist mismatch: expected {expected}, got {actual}")
    return actual


def verify_artifact(
    archive_path: Path,
    *,
    source_sha: str,
    version: str,
    build: str,
    bundle_id: str,
    min_os: str,
    expected_digest: str | None = None,
    expected_size: int | None = None,
    extract_to: Path | None = None,
) -> dict:
    if not re.fullmatch(r"[0-9a-fA-F]{40}", source_sha):
        raise ValueError("source SHA must be a full 40-character commit SHA")
    if not archive_path.is_file():
        raise FileNotFoundError(f"Artifact archive does not exist: {archive_path}")

    archive_bytes = archive_path.read_bytes()
    archive_digest = sha256(archive_bytes)
    if expected_size is not None and len(archive_bytes) != expected_size:
        raise ValueError(f"Artifact size mismatch: expected {expected_size}, got {len(archive_bytes)}")
    normalized_expected_digest = normalize_digest(expected_digest)
    if normalized_expected_digest and archive_digest != normalized_expected_digest:
        raise ValueError(f"Artifact digest mismatch: expected {normalized_expected_digest}, got {archive_digest}")

    try:
        with zipfile.ZipFile(io.BytesIO(archive_bytes)) as artifact:
            names = [name for name in artifact.namelist() if not name.endswith("/")]
            expected_ipa_names = {"RouteLocation-unsigned.ipa", f"RouteLocation-v{version}-unsigned.ipa"}
            if len(names) != 2 or set(names) != expected_ipa_names:
                raise ValueError(f"Artifact must contain exactly {sorted(expected_ipa_names)}; got {names}")
            ipa_contents = {name: artifact.read(name) for name in names}
    except zipfile.BadZipFile as error:
        raise ValueError(f"Invalid GitHub artifact archive: {error}") from error

    versioned_name = f"RouteLocation-v{version}-unsigned.ipa"
    if versioned_name not in ipa_contents:
        raise ValueError(f"Artifact does not contain the expected versioned IPA {versioned_name}")
    if ipa_contents["RouteLocation-unsigned.ipa"] != ipa_contents[versioned_name]:
        raise ValueError("Generic and versioned IPA files are not byte-identical")

    ipa_reports = {}
    for name in sorted(expected_ipa_names):
        data = ipa_contents[name]
        metadata = inspect_ipa(data, version=version, build=build, bundle_id=bundle_id, min_os=min_os)
        ipa_reports[name] = {
            "bytes": len(data),
            "sha256": sha256(data),
            "metadata": metadata,
        }
        if extract_to is not None:
            extract_to.mkdir(parents=True, exist_ok=True)
            (extract_to / name).write_bytes(data)

    return {
        "sourceSHA": source_sha.lower(),
        "artifactBytes": len(archive_bytes),
        "artifactSHA256": archive_digest,
        "ipas": ipa_reports,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--source-sha", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--bundle-id", default="com.routelocation.app")
    parser.add_argument("--min-os", default="17.4")
    parser.add_argument("--expected-digest")
    parser.add_argument("--expected-size", type=int)
    parser.add_argument("--extract-to", type=Path)
    args = parser.parse_args()

    report = verify_artifact(
        args.archive,
        source_sha=args.source_sha,
        version=args.version,
        build=args.build,
        bundle_id=args.bundle_id,
        min_os=args.min_os,
        expected_digest=args.expected_digest,
        expected_size=args.expected_size,
        extract_to=args.extract_to,
    )
    print(json.dumps(report, sort_keys=True))


if __name__ == "__main__":
    main()
