"""Windows-friendly structural checks; real Swift compilation runs on macOS CI."""

from pathlib import Path
import json
import plistlib
import sys
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[1]
errors: list[str] = []


def require(condition: bool, message: str) -> None:
    if not condition:
        errors.append(message)


for relative in ("StikDebug/Info.plist", "StikDebug/StikDebug.entitlements"):
    with (ROOT / relative).open("rb") as handle:
        plistlib.load(handle)

ET.parse(ROOT / "StikDebug.xcodeproj/xcshareddata/xcschemes/StikDebug.xcscheme")

project = (ROOT / "StikDebug.xcodeproj/project.pbxproj").read_text(encoding="utf-8")
require(project.count("{") == project.count("}"), "Unbalanced braces in project.pbxproj")
require(project.count("(") == project.count(")"), "Unbalanced parentheses in project.pbxproj")
require(project.count("PRODUCT_NAME = RouteLocation;") == 2, "RouteLocation product name must exist in Debug and Release")
require("IPHONEOS_DEPLOYMENT_TARGET = 17.4;" in project, "iOS 17.4 deployment target missing")
require("TARGETED_DEVICE_FAMILY = 1;" in project, "App target must be iPhone-only")

swift = "\n".join(path.read_text(encoding="utf-8") for path in (ROOT / "StikDebug").rglob("*.swift"))
require("overpass-api" not in swift.lower(), "Overpass must not influence playback")
require("expectedTravelTime" not in swift, "MKRoute expected travel time must not influence playback")
require("CoordinateImportParser" in swift, "Coordinate parser missing")
require("truncatingRemainder" in swift, "Infinite-loop modulo math missing")
require("systemUptime" in swift, "Monotonic playback clock missing")

workflow = (ROOT / ".github/workflows/build_ipa.yml").read_text(encoding="utf-8")
for token in ("workflow_dispatch", "runs-on: macos-latest", "CODE_SIGNING_ALLOWED=NO", "Payload/RouteLocation.app", "RouteLocation-unsigned.ipa", "xcodebuild test"):
    require(token in workflow, f"Workflow requirement missing: {token}")

license_text = (ROOT / "LICENSE").read_text(encoding="utf-8", errors="ignore")
require("GNU AFFERO GENERAL PUBLIC LICENSE" in license_text, "AGPL license missing")

source_file = ROOT / "source.json"
require(source_file.is_file(), "source.json missing from repository root")
if source_file.is_file():
    try:
        with source_file.open("r", encoding="utf-8-sig") as f:
            source_data = json.load(f)
        require(source_data.get("name") == "RouteLocation Source", "source.json name must be 'RouteLocation Source'")
        require(source_data.get("identifier") == "com.routelocation.source", "source.json identifier must be 'com.routelocation.source'")
        require(isinstance(source_data.get("apps"), list) and len(source_data["apps"]) > 0, "source.json must have apps list")
        if source_data.get("apps"):
            app = source_data["apps"][0]
            require(app.get("bundleIdentifier") == "com.routelocation.app", "source.json bundleIdentifier mismatch")
            require(app.get("name") == "RouteLocation", "source.json app name mismatch")
            versions = app.get("versions", [])
            require(len(versions) > 0, "source.json must contain at least one version")
            for v in versions:
                require(bool(v.get("version")), "Version missing version string")
                require(bool(v.get("downloadURL")), "Version missing downloadURL")
                require(isinstance(v.get("size"), int) and v["size"] > 0, "Version size must be positive int")
                require(bool(v.get("minOSVersion")), "Version missing minOSVersion")
    except Exception as e:
        errors.append(f"Failed to parse source.json: {e}")


if errors:
    for error in errors:
        print(f"ERROR: {error}")
    sys.exit(1)

print("Repository structure checks passed")
