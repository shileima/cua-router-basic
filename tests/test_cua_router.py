import importlib.util
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


if __name__ == "__main__":
    unittest.main()
