"""Verify this self-contained Demo snapshot without using its original folder."""

import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import unittest
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[1]
SNAPSHOT = json.loads((ROOT / "DEMO-SNAPSHOT.json").read_text(encoding="utf-8"))


def git(*arguments):
    return subprocess.check_output(["git", *arguments], cwd=ROOT)


class DemoSnapshotTests(unittest.TestCase):
    def test_git_history_is_independent(self):
        self.assertFalse((ROOT / ".git/objects/info/alternates").exists())
        git("cat-file", "-e", SNAPSHOT["source_commit"] + "^{commit}")
        git("merge-base", "--is-ancestor", SNAPSHOT["source_commit"], "HEAD")
        result = subprocess.run(
            ["git", "fsck", "--full"], cwd=ROOT, capture_output=True, text=True
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_manifest_covers_the_complete_source_version(self):
        names = git("ls-tree", "-r", "--name-only", "-z", SNAPSHOT["source_commit"])
        expected = sorted(name.decode("utf-8") for name in names.split(b"\0") if name)
        self.assertEqual(sorted(SNAPSHOT["source_files"]), expected)
        self.assertEqual(SNAPSHOT["source_file_count"], len(expected))

    def test_all_saved_file_hashes_match(self):
        files = dict(SNAPSHOT["source_files"])
        files.update(SNAPSHOT["save_files"])
        for name, info in files.items():
            with self.subTest(path=name):
                path = ROOT / name
                self.assertTrue(path.is_file(), name)
                data = path.read_bytes()
                self.assertEqual(len(data), info["bytes"])
                self.assertEqual(hashlib.sha256(data).hexdigest(), info["sha256"])

    def test_saved_source_matches_its_recorded_git_commit(self):
        result = subprocess.run(
            ["git", "diff", "--exit-code", SNAPSHOT["source_commit"], "--",
             *SNAPSHOT["source_files"]],
            cwd=ROOT, capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_xcode_project_and_demo_resources_are_present(self):
        required = [
            "ios/Yueshan.xcodeproj/project.pbxproj",
            "ios/Yueshan.xcodeproj/xcshareddata/xcschemes/Yueshan.xcscheme",
            "ios/Yueshan/Resources/library.json",
            "ios/YueshanTests/Fixtures/ReaderTestFont.ttf",
            "ios/YueshanUITests/ReaderFlowTests.swift",
            "ios/README.md", "ios/FEATURES.md", "ios/QA.md",
            "package.json", "server.mjs", "index.html",
        ]
        for name in required:
            self.assertTrue((ROOT / name).is_file(), name)
        ET.parse(ROOT / required[1])
        with (ROOT / "ios/Yueshan/Info.plist").open("rb") as stream:
            plistlib.load(stream)
        books = json.loads((ROOT / required[2]).read_text(encoding="utf-8"))
        self.assertEqual(len(books), 8)
        self.assertEqual(len({book["id"] for book in books}), 8)
        self.assertTrue(all(book["chapters"] and book["content"] for book in books))
        project = (ROOT / required[0]).read_text(encoding="utf-8")
        self.assertNotIn("/Users/", project)

    def test_save_notes_identify_the_source_version(self):
        notes = (ROOT / "保存说明.md").read_text(encoding="utf-8")
        self.assertIn(SNAPSHOT["source_commit"], notes)
        self.assertIn("ios/Yueshan.xcodeproj", notes)
        self.assertEqual(SNAPSHOT["timezone"], "Asia/Shanghai")

    def test_source_manifest_excludes_generated_build_artifacts(self):
        for name in SNAPSHOT["source_files"]:
            self.assertNotIn("node_modules", Path(name).parts)
            self.assertNotIn("DerivedData", Path(name).parts)
            self.assertNotIn(".git", Path(name).parts)
            self.assertFalse(any(part.endswith(".xcresult") for part in Path(name).parts))


if __name__ == "__main__":
    unittest.main(verbosity=2)
