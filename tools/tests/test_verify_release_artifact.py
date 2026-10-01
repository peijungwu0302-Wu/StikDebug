import hashlib
import io
import plistlib
from pathlib import Path
import sys
import tempfile
import unittest
import zipfile


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))

from verify_release_artifact import verify_artifact  # noqa: E402


def make_ipa(*, version="1.2.19", build="15", bundle="com.routelocation.app", min_os="17.4"):
    output = io.BytesIO()
    info = plistlib.dumps({
        "CFBundleIdentifier": bundle,
        "CFBundleShortVersionString": version,
        "CFBundleVersion": build,
        "MinimumOSVersion": min_os,
    })
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("Payload/RouteLocation.app/Info.plist", info)
        archive.writestr("Payload/RouteLocation.app/placeholder", b"app")
    return output.getvalue()


def make_artifact(path: Path, generic: bytes, versioned: bytes | None = None):
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("RouteLocation-unsigned.ipa", generic)
        archive.writestr("RouteLocation-v1.2.19-unsigned.ipa", versioned if versioned is not None else generic)
    path.write_bytes(output.getvalue())
    return output.getvalue()


class VerifyReleaseArtifactTests(unittest.TestCase):
    def test_accepts_byte_identical_ipas_with_expected_metadata_and_digest(self):
        ipa = make_ipa()
        with tempfile.TemporaryDirectory() as directory:
            archive_path = Path(directory) / "artifact.zip"
            extract_path = Path(directory) / "verified"
            artifact_bytes = make_artifact(archive_path, ipa)
            report = verify_artifact(
                archive_path,
                source_sha="a" * 40,
                version="1.2.19",
                build="15",
                bundle_id="com.routelocation.app",
                min_os="17.4",
                expected_digest=f"sha256:{hashlib.sha256(artifact_bytes).hexdigest()}",
                expected_size=len(artifact_bytes),
                extract_to=extract_path,
            )
            self.assertEqual(report["ipas"]["RouteLocation-v1.2.19-unsigned.ipa"]["sha256"], hashlib.sha256(ipa).hexdigest())
            self.assertEqual((extract_path / "RouteLocation-unsigned.ipa").read_bytes(), ipa)
            self.assertEqual((extract_path / "RouteLocation-v1.2.19-unsigned.ipa").read_bytes(), ipa)

    def test_rejects_non_identical_ipa_copies(self):
        with tempfile.TemporaryDirectory() as directory:
            archive_path = Path(directory) / "artifact.zip"
            make_artifact(archive_path, make_ipa(), make_ipa(build="16"))
            with self.assertRaisesRegex(ValueError, "not byte-identical"):
                verify_artifact(archive_path, source_sha="b" * 40, version="1.2.19", build="15", bundle_id="com.routelocation.app", min_os="17.4")

    def test_rejects_plist_metadata_mismatch(self):
        with tempfile.TemporaryDirectory() as directory:
            archive_path = Path(directory) / "artifact.zip"
            make_artifact(archive_path, make_ipa(bundle="com.example.other"))
            with self.assertRaisesRegex(ValueError, "Info.plist mismatch"):
                verify_artifact(archive_path, source_sha="c" * 40, version="1.2.19", build="15", bundle_id="com.routelocation.app", min_os="17.4")

    def test_rejects_extra_or_missing_artifact_files(self):
        with tempfile.TemporaryDirectory() as directory:
            archive_path = Path(directory) / "artifact.zip"
            archive_path.write_bytes(b"not a zip")
            with self.assertRaisesRegex(ValueError, "Invalid GitHub artifact"):
                verify_artifact(archive_path, source_sha="d" * 40, version="1.2.19", build="15", bundle_id="com.routelocation.app", min_os="17.4")

    def test_rejects_artifact_digest_mismatch(self):
        with tempfile.TemporaryDirectory() as directory:
            archive_path = Path(directory) / "artifact.zip"
            make_artifact(archive_path, make_ipa())
            with self.assertRaisesRegex(ValueError, "Artifact digest mismatch"):
                verify_artifact(archive_path, source_sha="e" * 40, version="1.2.19", build="15", bundle_id="com.routelocation.app", min_os="17.4", expected_digest="sha256:" + "0" * 64)


if __name__ == "__main__":
    unittest.main()
