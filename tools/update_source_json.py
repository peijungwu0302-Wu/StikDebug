#!/usr/bin/env python3
"""
RouteLocation SideStore Source Updater
Updates source.json with newly released versions, preventing duplicates,
sorting semantically (1.2.10 > 1.2.9), extracting metadata from IPA if provided,
and writing back atomically.
"""

from __future__ import annotations
import argparse
from datetime import date
import json
import os
from pathlib import Path
import plistlib
import re
import sys
import zipfile


def parse_semver_key(v_str: str) -> list[int]:
    """Extract integer components for accurate semantic sorting."""
    parts = re.findall(r"\d+", v_str)
    return [int(p) for p in parts] if parts else [0]


def inspect_ipa(ipa_path: Path) -> dict:
    """Inspect unsigned IPA file and extract bundle ID, version, build version, and size."""
    if not ipa_path.is_file():
        raise FileNotFoundError(f"IPA not found at: {ipa_path}")
    
    size_bytes = ipa_path.stat().st_size
    info_plist_data = None
    
    with zipfile.ZipFile(ipa_path, "r") as z:
        for name in z.namelist():
            if name.endswith(".app/Info.plist"):
                info_plist_data = z.read(name)
                break
                
    if not info_plist_data:
        raise ValueError(f"Could not locate Info.plist inside {ipa_path}")
        
    plist = plistlib.loads(info_plist_data)
    bundle_id = plist.get("CFBundleIdentifier")
    version = plist.get("CFBundleShortVersionString")
    build_version = plist.get("CFBundleVersion")
    min_os = plist.get("MinimumOSVersion", "17.4")
    
    return {
        "bundleIdentifier": bundle_id,
        "version": version,
        "buildVersion": build_version,
        "size": size_bytes,
        "minOSVersion": min_os,
    }


def update_source(
    source_path: Path,
    version: str,
    release_date: str,
    size: int,
    download_url: str,
    localized_description: str | None = None,
    min_os_version: str = "17.4",
    app_permissions: dict | None = None,
) -> None:
    if not source_path.is_file():
        raise FileNotFoundError(f"source.json not found at: {source_path}")

    with source_path.open("r", encoding="utf-8-sig") as f:
        data = json.load(f)

    if "apps" not in data or not data["apps"]:
        raise ValueError("source.json has invalid structure: missing 'apps' array")

    app = data["apps"][0]
    versions = app.get("versions", [])

    # Default permissions if not supplied
    if not app_permissions:
        app_permissions = {
            "entitlements": [
                "com.apple.developer.networking.networkextension"
            ],
            "privacy": {
                "NSLocationAlwaysAndWhenInUseUsageDescription": "用於路線播放時在背景持續傳送開發者位置模擬訊號。",
                "NSHealthShareUsageDescription": "用於讀取 Apple 健康步數權限與狀態。",
                "NSHealthUpdateUsageDescription": "用於在路線播放時將模擬運動步數寫入 Apple 健康。"
            }
        }

    # Construct the new or updated version dictionary
    new_entry = {
        "version": version,
        "date": release_date,
        "size": size,
        "downloadURL": download_url,
        "localizedDescription": localized_description or f"RouteLocation {version} 發行版本。",
        "minOSVersion": min_os_version,
        "appPermissions": app_permissions,
    }

    # Duplicate prevention: find existing entry with same version
    existing_idx = None
    for idx, v_entry in enumerate(versions):
        if v_entry.get("version") == version:
            existing_idx = idx
            break

    if existing_idx is not None:
        print(f"Updating existing version entry for {version}")
        # Preserve existing description if none provided
        if not localized_description and "localizedDescription" in versions[existing_idx]:
            new_entry["localizedDescription"] = versions[existing_idx]["localizedDescription"]
        versions[existing_idx] = new_entry
    else:
        print(f"Adding new version entry for {version}")
        versions.append(new_entry)

    # Sort descending by semantic version (newest first)
    versions.sort(key=lambda x: parse_semver_key(x.get("version", "0")), reverse=True)
    app["versions"] = versions

    # Write atomically
    tmp_path = source_path.with_suffix(".tmp")
    with tmp_path.open("w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")
    tmp_path.replace(source_path)
    print(f"Successfully updated {source_path} (now {len(versions)} versions registered).")


def main() -> None:
    parser = argparse.ArgumentParser(description="Update source.json with release metadata")
    parser.add_argument("--source-path", type=Path, default=Path(__file__).resolve().parents[1] / "source.json")
    parser.add_argument("--ipa-path", type=Path, help="Path to unsigned IPA to inspect")
    parser.add_argument("--version", type=str, help="Version string, e.g. 1.2.6")
    parser.add_argument("--tag", type=str, help="Git tag, e.g. routelocation-v1.2.6")
    parser.add_argument("--date", type=str, default=str(date.today()), help="Release date YYYY-MM-DD")
    parser.add_argument("--size", type=int, help="File size in bytes")
    parser.add_argument("--download-url", type=str, help="Direct download URL")
    parser.add_argument("--repo", type=str, default="peijungwu0302-Wu/StikDebug", help="GitHub repo (owner/repo)")
    parser.add_argument("--description", type=str, help="Localized release notes")
    parser.add_argument("--min-os", type=str, default="17.4", help="Minimum iOS version")

    args = parser.parse_args()

    version = args.version
    size = args.size
    min_os = args.min_os

    if args.ipa_path:
        print(f"Inspecting IPA: {args.ipa_path}")
        ipa_info = inspect_ipa(args.ipa_path)
        if ipa_info["bundleIdentifier"] != "com.routelocation.app":
            raise ValueError(f"Unexpected bundle identifier: {ipa_info['bundleIdentifier']}")
        if not version:
            version = ipa_info["version"]
        if not size:
            size = ipa_info["size"]
        if ipa_info.get("minOSVersion"):
            min_os = ipa_info["minOSVersion"]

    if not version:
        if args.tag and args.tag.startswith("routelocation-v"):
            version = args.tag[len("routelocation-v"):]
        else:
            raise ValueError("Version must be specified via --version, --ipa-path, or --tag")

    tag = args.tag or f"routelocation-v{version}"
    download_url = args.download_url
    if not download_url:
        asset_name = args.ipa_path.name if args.ipa_path else f"RouteLocation-v{version}-unsigned.ipa"
        download_url = f"https://github.com/{args.repo}/releases/download/{tag}/{asset_name}"

    if size is None:
        raise ValueError("Size must be specified via --size or --ipa-path")

    update_source(
        source_path=args.source_path,
        version=version,
        release_date=args.date,
        size=size,
        download_url=download_url,
        localized_description=args.description,
        min_os_version=min_os,
    )


if __name__ == "__main__":
    main()
