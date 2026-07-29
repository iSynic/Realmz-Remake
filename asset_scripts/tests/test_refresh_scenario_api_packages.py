import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

SCRIPT_PATH = Path(__file__).resolve().parents[1] / "refresh_scenario_api_packages.py"
SPEC = importlib.util.spec_from_file_location(
    "refresh_scenario_api_packages",
    SCRIPT_PATH,
)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)
canonical_bytes = MODULE.canonical_bytes
refresh_package = MODULE.refresh_package
sha256 = MODULE.sha256


class RefreshScenarioApiPackagesTests(unittest.TestCase):
    def test_refreshes_script_and_manifest_integrity(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            scripts_path = root / "remake" / "scripts.json"
            scripts_path.parent.mkdir(parents=True)
            scripts_path.write_text(
                '{"capabilityCatalogHash":"old","schemaVersion":2}',
                encoding="utf-8",
            )
            manifest_path = root / "campaign.json"
            manifest_path.write_text(
                json.dumps({
                    "capabilities": {
                        "scriptExecutionTiers": ["safe", "sandboxed"],
                    },
                    "format": "realmz-remake-scenario",
                    "integrity": {
                        "algorithm": "sha256",
                        "files": {
                            "remake/scripts.json": {
                                "bytes": 1,
                                "sha256": "old",
                            }
                        },
                        "packageHash": "old",
                    },
                }),
                encoding="utf-8",
            )
            runtime_path = root / "runtime.json"
            runtime_path.write_text(
                '{"schemaVersion":2}',
                encoding="utf-8",
            )
            provenance_path = root.with_name(f"{root.name}.provenance.json")
            provenance_path.write_text(
                json.dumps({
                    "files": [
                        {"path": "campaign.json", "bytes": 1, "sha256": "old"},
                        {
                            "path": "remake/scripts.json",
                            "bytes": 1,
                            "sha256": "old",
                        },
                        {"path": "runtime.json", "bytes": 1, "sha256": "old"},
                    ]
                }),
                encoding="utf-8",
            )

            self.assertTrue(refresh_package(root, "new", False))
            scripts_bytes = scripts_path.read_bytes()
            scripts = json.loads(scripts_bytes)
            manifest = json.loads(manifest_path.read_bytes())
            provenance = json.loads(provenance_path.read_bytes())
            self.assertEqual(scripts["capabilityCatalogHash"], "new")
            self.assertEqual(
                manifest["integrity"]["files"]["remake/scripts.json"],
                {"bytes": len(scripts_bytes), "sha256": sha256(scripts_bytes)},
            )
            package_hash = manifest["integrity"].pop("packageHash")
            self.assertEqual(package_hash, sha256(canonical_bytes(manifest)))
            self.assertEqual(
                provenance["files"],
                [
                    {
                        "path": "campaign.json",
                        "bytes": len(manifest_path.read_bytes()),
                        "sha256": sha256(manifest_path.read_bytes()),
                    },
                    {
                        "path": "remake/scripts.json",
                        "bytes": len(scripts_bytes),
                        "sha256": sha256(scripts_bytes),
                    },
                    {
                        "path": "runtime.json",
                        "bytes": len(runtime_path.read_bytes()),
                        "sha256": sha256(runtime_path.read_bytes()),
                    },
                ],
            )
            self.assertFalse(refresh_package(root, "new", True))

    def test_rejects_removed_trusted_execution_tier(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            scripts_path = root / "remake" / "scripts.json"
            scripts_path.parent.mkdir(parents=True)
            scripts_path.write_text(
                '{"capabilityCatalogHash":"old","schemaVersion":2}',
                encoding="utf-8",
            )
            (root / "campaign.json").write_text(
                json.dumps({
                    "capabilities": {
                        "scriptExecutionTiers": ["safe", "trusted"],
                    },
                    "integrity": {
                        "files": {
                            "remake/scripts.json": {
                                "bytes": 1,
                                "sha256": "old",
                            }
                        },
                    },
                }),
                encoding="utf-8",
            )

            with self.assertRaisesRegex(
                ValueError,
                "unsupported script execution tiers.*trusted",
            ):
                refresh_package(root, "new", False)


if __name__ == "__main__":
    unittest.main()
