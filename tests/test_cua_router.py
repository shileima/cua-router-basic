import importlib.util
import json
import os
import subprocess
import sys
from pathlib import Path
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPTS_DIR = ROOT / "scripts"
MODULE_PATH = SCRIPTS_DIR / "cua-router.py"

sys.path.insert(0, str(SCRIPTS_DIR))
import vendor_paths  # noqa: E402

spec = importlib.util.spec_from_file_location("cua_router", MODULE_PATH)
cua_router = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cua_router)


class ReplCodeWrappingTests(unittest.TestCase):
    def test_wraps_code_in_block_scope(self):
        wrapped = cua_router.wrap_js_for_repl(
            'const s = await sky.get_app_state({ app: "com.google.Chrome" });\n'
            "nodeRepl.write(s.text);"
        )

        self.assertTrue(wrapped.startswith("{\n"))
        self.assertIn("const s = await sky.get_app_state", wrapped)
        self.assertTrue(wrapped.endswith("\n}"))

    def test_wrap_keeps_repeated_const_declarations_out_of_repl_global_scope(self):
        first = cua_router.wrap_js_for_repl('const s = "first"; nodeRepl.write(s);')
        second = cua_router.wrap_js_for_repl('const s = "second"; nodeRepl.write(s);')

        self.assertEqual(first.count("const s"), 1)
        self.assertEqual(second.count("const s"), 1)
        self.assertNotEqual(first, second)
        self.assertTrue(first.startswith("{\n"))
        self.assertTrue(second.startswith("{\n"))


class VendorPathTests(unittest.TestCase):
    def test_event_stream_shares_app_server_runtime(self):
        self.assertEqual(vendor_paths.event_stream_home(), vendor_paths.RUNTIME)


class VendorSetupScriptTests(unittest.TestCase):
    def test_setup_vendor_preserves_notarized_computer_use_app(self):
        script = (SCRIPTS_DIR / "setup-vendor.sh").read_text(encoding="utf-8")

        self.assertNotIn("patch-computer-use-branding.sh", script)
        self.assertIn("codesign --verify --deep --strict", script)
        self.assertIn("spctl --assess --type execute", script)

    def test_branding_patch_script_does_not_resign_app(self):
        script = (SCRIPTS_DIR / "patch-computer-use-branding.sh").read_text(encoding="utf-8")

        self.assertNotIn("PlistBuddy", script)
        self.assertNotIn("codesign --force --sign -", script)
        self.assertIn("preserve notarized signature", script)


class RouterIdentityTests(unittest.TestCase):
    def test_router_identity_reports_current_install(self):
        identity = cua_router.router_identity()

        self.assertEqual(identity["service"], "cua-router-basic")
        self.assertEqual(Path(identity["skill_root"]), ROOT)
        self.assertEqual(Path(identity["runtime_dir"]), vendor_paths.RUNTIME)
        self.assertEqual(Path(identity["computer_use_app"]), vendor_paths.computer_use_app())
        self.assertEqual(Path(identity["codex_bin"]), vendor_paths.codex_bin())
        meta = json.loads((ROOT / ".meta.json").read_text(encoding="utf-8"))
        self.assertEqual(identity["version"], meta["version"])
        self.assertIsInstance(identity["pid"], int)


class RecordDeskResolveRootTests(unittest.TestCase):
    def test_prefers_sibling_cua_router_before_global_automan_install(self):
        resolver = ROOT / "record-desk-basic" / "scripts" / "lib" / "resolve-cua-root.sh"
        sky_rel = (
            "vendor/computer-use/Codex Computer Use.app/Contents/SharedSupport/"
            "SkyComputerUseClient.app/Contents/MacOS/SkyComputerUseClient"
        )

        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            skills_dir = tmp_path / "agent" / "skills"
            rdb_root = skills_dir / "record-desk-basic"
            sibling_root = skills_dir / "cua-router-basic"
            global_root = tmp_path / ".automan" / "skills" / "cua-router-basic"

            for root in (sibling_root, global_root):
                sky_bin = root / sky_rel
                sky_bin.parent.mkdir(parents=True, exist_ok=True)
                sky_bin.write_text("#!/bin/sh\n", encoding="utf-8")
                sky_bin.chmod(0o755)
            rdb_root.mkdir(parents=True)

            command = (
                f'source "{resolver}"; '
                f'resolve_cua_root "{rdb_root}"'
            )
            env = {**os.environ, "HOME": str(tmp_path)}
            result = subprocess.run(
                ["bash", "-lc", command],
                check=True,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env=env,
            )

        self.assertEqual(result.stdout, str(sibling_root))


class InstallHelperTests(unittest.TestCase):
    COMMON = ROOT / "scripts" / "lib" / "common.sh"

    def _write_fake_skill(self, source):
        (source / "scripts").mkdir(parents=True)
        (source / "record-desk-basic" / "scripts").mkdir(parents=True)
        (source / "SKILL.md").write_text("name: cua-router-basic\n", encoding="utf-8")
        (source / "record-desk-basic" / "SKILL.md").write_text(
            "name: record-desk-basic\n", encoding="utf-8"
        )
        (source / "scripts" / "daemon.sh").write_text("#!/bin/sh\n", encoding="utf-8")

    def _run_sync(self, source, tmp_path, env_extra):
        command = f'source "{self.COMMON}"; common_init; sync_automan_install "{source}"'
        env = {**os.environ, "HOME": str(tmp_path), **env_extra}
        return subprocess.run(
            ["bash", "-lc", command],
            check=True,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env,
        )

    def test_sync_automan_install_writes_real_dirs_into_cua_agent_profile(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            source = tmp_path / "source" / "cua-router-basic"
            cua_profile = tmp_path / ".automan" / "claude-code-agents" / "cua-agent"
            self._write_fake_skill(source)
            cua_profile.mkdir(parents=True)

            self._run_sync(source, tmp_path, {
                "CUA_ROUTER_AUTOMAN_PROFILE_DIR": str(cua_profile),
            })

            skills_dir = cua_profile / "skills"
            router_target = skills_dir / "cua-router-basic"
            rdb_target = skills_dir / "record-desk-basic"

            self.assertTrue(router_target.is_dir())
            self.assertFalse(router_target.is_symlink())
            self.assertTrue((router_target / "SKILL.md").is_file())

            self.assertTrue(rdb_target.is_dir())
            self.assertFalse(rdb_target.is_symlink())
            self.assertTrue((rdb_target / "SKILL.md").is_file())

    def test_sync_automan_install_is_noop_when_profile_missing(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            source = tmp_path / "source" / "cua-router-basic"
            cua_profile = tmp_path / ".automan" / "claude-code-agents" / "cua-agent"
            self._write_fake_skill(source)

            self._run_sync(source, tmp_path, {
                "CUA_ROUTER_AUTOMAN_PROFILE_DIR": str(cua_profile),
            })

            self.assertFalse(cua_profile.exists())

    def test_sync_automan_install_cleans_up_legacy_layout(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            source = tmp_path / "source" / "cua-router-basic"
            agents_root = tmp_path / ".automan" / "claude-code-agents"
            cua_profile = agents_root / "cua-agent"
            main_profile = agents_root / "main"
            legacy_skills = tmp_path / ".automan" / "skills"
            self._write_fake_skill(source)
            cua_profile.mkdir(parents=True)

            legacy_router = legacy_skills / "cua-router-basic"
            legacy_rdb = legacy_skills / "record-desk-basic"
            legacy_router.mkdir(parents=True)
            (legacy_router / "SKILL.md").write_text("stale\n", encoding="utf-8")
            legacy_rdb.mkdir(parents=True)
            (legacy_rdb / "SKILL.md").write_text("stale\n", encoding="utf-8")

            (main_profile / "skills").mkdir(parents=True)
            os.symlink(
                "../../../skills/cua-router-basic",
                main_profile / "skills" / "cua-router-basic",
            )
            os.symlink(
                "../../../skills/record-desk-basic",
                main_profile / "skills" / "record-desk-basic",
            )

            self._run_sync(source, tmp_path, {
                "CUA_ROUTER_AUTOMAN_PROFILE_DIR": str(cua_profile),
                "CUA_ROUTER_LEGACY_AUTOMAN_SKILLS_DIR": str(legacy_skills),
                "CUA_ROUTER_AUTOMAN_ROOT": str(tmp_path / ".automan"),
            })

            self.assertFalse(legacy_router.exists())
            self.assertFalse(legacy_rdb.exists())
            self.assertFalse((main_profile / "skills" / "cua-router-basic").exists())
            self.assertFalse((main_profile / "skills" / "record-desk-basic").exists())
            self.assertTrue((cua_profile / "skills" / "cua-router-basic" / "SKILL.md").is_file())
            self.assertTrue((cua_profile / "skills" / "record-desk-basic" / "SKILL.md").is_file())

    def test_release_slim_archive_includes_record_desk_basic(self):
        with tempfile.TemporaryDirectory() as tmp:
            out_dir = Path(tmp)
            subprocess.run(
                [
                    "bash",
                    str(ROOT / "scripts" / "package-release.sh"),
                    "--skip-vendor",
                    "--out-dir",
                    str(out_dir),
                    "--version",
                    "0.0.0-test",
                ],
                check=True,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            archive = out_dir / "cua-router-basic-slim-0.0.0-test.tar.gz"
            listing = subprocess.run(
                ["tar", "-tzf", str(archive)],
                check=True,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            ).stdout

        self.assertIn("record-desk-basic/SKILL.md", listing)


if __name__ == "__main__":
    unittest.main()
