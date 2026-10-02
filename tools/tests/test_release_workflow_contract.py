from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]


class ReleaseWorkflowContractTests(unittest.TestCase):
    def test_feature_build_does_not_rebuild_main_or_production_tags(self) -> None:
        workflow = (ROOT / ".github/workflows/build_ipa.yml").read_text(encoding="utf-8")
        self.assertIn("branches: ['feat/**']", workflow)
        self.assertIn("- 'routelocation-test-v*'", workflow)
        self.assertNotRegex(workflow, r"(?m)^\s*- 'routelocation-v\*'\s*$")
        self.assertIn("name: RouteLocation-unsigned-${{ github.sha }}", workflow)
        self.assertIn("- 'README.en.md'", workflow)
        self.assertNotIn("Publish public GitHub Release", workflow)

    def test_production_promotion_has_no_build_or_test_commands(self) -> None:
        workflow = (ROOT / ".github/workflows/promote_release.yml").read_text(encoding="utf-8")
        self.assertIn("- 'routelocation-v*'", workflow)
        self.assertRegex(workflow, r"(?m)^\s*workflow_dispatch:")
        self.assertRegex(workflow, r"(?m)^\s*dry_run:\s*$")
        self.assertNotRegex(workflow, r"\b(?:xcodebuild|xcrun)\b")

    def test_artifact_discovery_requires_unique_exact_sha_candidate(self) -> None:
        workflow = (ROOT / ".github/workflows/promote_release.yml").read_text(encoding="utf-8")
        self.assertIn('EXPECTED_NAME="RouteLocation-unsigned-${SOURCE_SHA}"', workflow)
        self.assertIn('"$RUN_SHA" != "$SOURCE_SHA"', workflow)
        self.assertIn('if [[ "$COUNT" -ne 1 ]]', workflow)
        self.assertIn('select(.name == $name and .expired == false)', workflow)

    def test_promotion_verifies_exact_artifact_before_publish_and_updates_source_from_ipa(self) -> None:
        workflow = (ROOT / ".github/workflows/promote_release.yml").read_text(encoding="utf-8")
        dry_run_block = workflow.split("- name: Complete promotion dry-run", 1)[1].split("- name: Create production GitHub Release", 1)[0]
        self.assertIn("No Release or source.json was changed", dry_run_block)
        self.assertIn("steps.release.outputs.dry_run != 'true'", workflow)
        self.assertIn('python3 tools/ensure_source_version_absent.py "$VERSION" source.json', workflow)
        self.assertIn('--ipa-path "$RUNNER_TEMP/verified-ipa/$VERSIONED_NAME"', workflow)
        self.assertIn('git rev-parse HEAD^', workflow)
        self.assertIn("previous-source-versions.json", workflow)


if __name__ == "__main__":
    unittest.main()
