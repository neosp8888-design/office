#!/usr/bin/env python3
"""Regression tests for the packaged backend release identity."""

from __future__ import annotations

import importlib.util
import hashlib
import plistlib
import tempfile
import unittest
from pathlib import Path


SCRIPT_PATH = Path(__file__).with_name("backend-release-id.py")
SPEC = importlib.util.spec_from_file_location("backend_release_id", SCRIPT_PATH)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class BackendReleaseIdentityTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary_directory.cleanup)
        self.app = Path(self.temporary_directory.name) / "OFFICESTRA.app"
        self.resources = self.app / "Contents" / "Resources"
        node_binary = b"node-binary-v1"
        fixture_files = {
            "OFFICESTRARuntime/backend/src/server.mjs": b"server-v1\n",
            "OFFICESTRARuntime/backend/package.json": b'{"type":"module"}\n',
            "OFFICESTRARuntime/backend/package-lock.json": b'{"lockfileVersion":3}\n',
            "OFFICESTRARuntime/database/migrations/001.sql": b"SELECT 1;\n",
            "OFFICESTRARuntime/infra/compose.yaml": b"services: {}\n",
            "OFFICESTRARuntime/node/bin/node": node_binary,
            "OFFICESTRARuntime/node/SHA256": (
                hashlib.sha256(node_binary).hexdigest().encode() + b"\n"
            ),
            "OFFICESTRARuntime/node/VERSION": b"22.17.0\n",
            "OFFICESTRARuntime/node/CDHASH": b"0123456789abcdef\n",
            "OFFICESTRARuntime/node/ENTITLEMENTS.plist": plistlib.dumps(
                {"com.apple.security.cs.allow-jit": True}
            ),
            "OfficeLLM_OfficeCore.bundle/characters.json": b'{"workdir":"/tmp/project"}\n',
        }
        for relative, content in fixture_files.items():
            path = self.resources / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(content)
        self.info_plist = self.app / "Contents" / "Info.plist"
        with self.info_plist.open("wb") as handle:
            plistlib.dump(
                {"OFFICESTRABackendReleaseID": "placeholder"},
                handle,
            )

    def test_identity_is_stable_for_unchanged_bundle(self) -> None:
        first = MODULE.calculate_release_id(self.app)
        second = MODULE.calculate_release_id(self.app)
        self.assertEqual(first, second)
        self.assertRegex(first, r"^[0-9a-f]{64}$")

    def test_each_new_runtime_input_changes_identity(self) -> None:
        paths = (
            "OFFICESTRARuntime/backend/package.json",
            "OFFICESTRARuntime/node/SHA256",
            "OFFICESTRARuntime/node/VERSION",
            "OFFICESTRARuntime/node/CDHASH",
            "OFFICESTRARuntime/node/ENTITLEMENTS.plist",
            "OfficeLLM_OfficeCore.bundle/characters.json",
        )
        original = MODULE.calculate_release_id(self.app)
        for relative in paths:
            with self.subTest(relative=relative):
                path = self.resources / relative
                before = path.read_bytes()
                path.write_bytes(before + b"changed")
                self.assertNotEqual(
                    MODULE.calculate_release_id(self.app),
                    original,
                )
                path.write_bytes(before)

    def test_signing_container_bytes_do_not_change_stable_identity(self) -> None:
        original = MODULE.calculate_release_id(self.app)
        node = self.resources / "OFFICESTRARuntime/node/bin/node"
        node.write_bytes(node.read_bytes() + b"timestamped-cms-signature")
        self.assertEqual(MODULE.calculate_release_id(self.app), original)

    def test_verification_uses_embedded_info_plist_value(self) -> None:
        release_id = MODULE.calculate_release_id(self.app)
        with self.info_plist.open("wb") as handle:
            plistlib.dump(
                {"OFFICESTRABackendReleaseID": release_id},
                handle,
            )
        self.assertEqual(MODULE.verify_release_id(self.app), release_id)

        node_version = self.resources / "OFFICESTRARuntime/node/VERSION"
        node_version.write_text("24.0.0\n", encoding="utf-8")
        with self.assertRaises(MODULE.ReleaseIdentityError):
            MODULE.verify_release_id(self.app)


if __name__ == "__main__":
    unittest.main()
