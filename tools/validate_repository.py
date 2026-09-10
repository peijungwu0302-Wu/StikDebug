"""Windows-friendly structural checks; real Swift compilation runs on macOS CI."""

from pathlib import Path
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

if errors:
    for error in errors:
        print(f"ERROR: {error}")
    sys.exit(1)

print("Repository structure checks passed")
