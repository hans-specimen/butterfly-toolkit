"""Exercise the CLI in disposable repositories; never tag the working project."""
import pathlib
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest


SOURCE = pathlib.Path(__file__).resolve().parents[2]


class VersionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="toolkit-version-")
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name)
        (self.root / "scripts").mkdir()
        script = SOURCE / "scripts/version.py"
        if script.exists():
            shutil.copy(script, self.root / "scripts/version.py")
        (self.root / "Config").mkdir()
        self.config = self.root / "Config/Version.xcconfig"
        self.set_version("1.2.3", 7)
        project = self.root / "Butterfly Toolkit.xcodeproj"
        project.mkdir()
        shutil.copy(SOURCE / "Butterfly Toolkit.xcodeproj/project.pbxproj", project)
        self.notes("1.2.3", 7)
        self.git("init", "-q")
        self.git("config", "user.email", "test@example.invalid")
        self.git("config", "user.name", "Version Test")
        self.git("config", "commit.gpgsign", "false")
        self.git("config", "tag.gpgsign", "false")
        self.commit()

    def git(self, *args):
        return subprocess.run(["git", *args], cwd=self.root, text=True,
                              capture_output=True, check=True).stdout.strip()

    def commit(self):
        self.git("add", ".")
        self.git("commit", "-qm", "test snapshot")

    def set_version(self, version, build):
        self.config.write_text(f"// Keep this comment.\nMARKETING_VERSION = {version}\n"
                               f"CURRENT_PROJECT_VERSION = {build}\n")

    def notes(self, version, build):
        (self.root / "CHANGELOG.md").write_text(
            f"# Changelog\n\n## [Unreleased]\n\n## [{version}] - 2026-11-07\n\n"
            f"Build: {build}\n\n- A usable local update.\n")

    def cli(self, *args, ok=True):
        result = subprocess.run([sys.executable, str(self.root / "scripts/version.py"), *args],
                                cwd=self.temp.name, text=True, capture_output=True)
        self.assertEqual(result.returncode == 0, ok, result.stdout + result.stderr)
        return result.stdout + result.stderr

    def test_show_and_check(self):
        self.assertIn("1.2.3 (7)", self.cli("show"))
        self.cli("check")

    def test_bumps_reset_components_and_increment_build_preserving_comments(self):
        for part, expected in [("patch", "1.2.4"), ("minor", "1.3.0"),
                               ("major", "2.0.0"), ("build", "1.2.3")]:
            with self.subTest(part=part):
                self.set_version("1.2.3", 7)
                self.cli("bump", part)
                self.assertIn(f"{expected} (8)", self.cli("show"))
                self.assertIn("// Keep this comment.", self.config.read_text())
                self.assertEqual(self.git("tag", "--list"), "")
                self.assertEqual(self.git("rev-list", "--count", "HEAD"), "1")

    def test_invalid_config_never_changes_file(self):
        for version, build in [("01.2.3", 7), ("1.2", 7), ("1.2.3-beta", 7),
                               ("1.2.3", 0), ("1.2.3", "01")]:
            with self.subTest(version=version, build=build):
                self.set_version(version, build)
                before = self.config.read_bytes()
                self.cli("bump", "patch", ok=False)
                self.assertEqual(self.config.read_bytes(), before)

    def test_duplicate_or_included_settings_rejected(self):
        original = self.config.read_text()
        for extra in ["MARKETING_VERSION = 2.0.0\n", '#include "Other.xcconfig"\n']:
            self.config.write_text(original + extra)
            self.cli("check", ok=False)

    def test_inline_xcode_override_rejected(self):
        project = self.root / "Butterfly Toolkit.xcodeproj/project.pbxproj"
        project.write_text(project.read_text().replace(
            "buildSettings = {", "buildSettings = {\n MARKETING_VERSION = 9.0.0;", 1))
        self.cli("check", ok=False)

    def test_missing_xcode_configuration_reference_rejected(self):
        project = self.root / "Butterfly Toolkit.xcodeproj/project.pbxproj"
        contents = plistlib.loads(subprocess.check_output(
            ["plutil", "-convert", "xml1", "-o", "-", str(project)]))
        objects = contents["objects"]
        configurations = objects[objects[contents["rootObject"]]["buildConfigurationList"]]
        configuration = objects[configurations["buildConfigurations"][0]]
        # 按工程结构移除引用，不依赖 Xcode 自动生成的标识或显示注释。
        self.assertIn("baseConfigurationReference", configuration)
        del configuration["baseConfigurationReference"]
        project.write_bytes(plistlib.dumps(contents))
        self.cli("check", ok=False)

    def test_milestone_requires_clean_tree_but_daily_check_does_not(self):
        self.cli("check", "--milestone")
        (self.root / "unfinished.txt").write_text("pending")
        self.cli("check")
        self.cli("check", "--milestone", ok=False)

    def test_milestone_requires_matching_notes_and_build(self):
        for text in ["# Changelog\n\n## [Unreleased]\n",
                     "## [1.2.3] - 2026-11-07\nBuild: 6\n- Fixed.\n",
                     "## [1.2.3] - 2026-11-07\nBuild: 7\n"]:
            (self.root / "CHANGELOG.md").write_text(text)
            self.commit()
            self.cli("check", "--milestone", ok=False)

    def test_tag_reuse_and_version_or_build_regression_rejected(self):
        self.git("tag", "-a", "v1.2.3", "-m", "stable")
        self.cli("check", "--milestone")
        for version, build in [("1.2.3", 8), ("1.2.2", 9), ("1.2.4", 7)]:
            self.set_version(version, build)
            self.notes(version, build)
            self.commit()
            self.cli("check", "--milestone", ok=False)
        self.set_version("1.2.4", 10)
        self.notes("1.2.4", 10)
        self.commit()
        self.cli("check", "--milestone")

    def test_lightweight_current_tag_rejected(self):
        self.git("tag", "v1.2.3")
        self.cli("check", "--milestone", ok=False)

    def test_branch_with_same_name_does_not_shadow_tag(self):
        self.git("tag", "-a", "v1.2.3", "-m", "stable")
        self.set_version("1.2.4", 8)
        self.notes("1.2.4", 8)
        self.commit()
        self.git("branch", "v1.2.3")
        self.cli("check", "--milestone")

    def test_shallow_history_rejected(self):
        (self.root / ".git/shallow").write_text(self.git("rev-parse", "HEAD") + "\n")
        self.cli("check", "--milestone", ok=False)

    def test_note_may_be_a_single_non_whitespace_character(self):
        notes = self.root / "CHANGELOG.md"
        notes.write_text(notes.read_text().replace("A usable local update.", "改"))
        self.commit()
        self.cli("check", "--milestone")

    def test_app_metadata_must_match(self):
        app = self.root / "build/Test.app"
        (app / "Contents").mkdir(parents=True)
        info = {"CFBundleShortVersionString": "1.2.3", "CFBundleVersion": "7",
                "CFBundleIdentifier": "com.hans.Butterfly-Toolkit"}
        target = app / "Contents/Info.plist"
        target.write_bytes(plistlib.dumps(info))
        self.cli("check", "--app", str(app))
        for key in info:
            bad = dict(info, **{key: "wrong"})
            target.write_bytes(plistlib.dumps(bad))
            self.cli("check", "--app", str(app), ok=False)


if __name__ == "__main__":
    unittest.main()
