import importlib.util
import sys
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPTS_DIR = ROOT / "scripts"
MODULE_PATH = SCRIPTS_DIR / "cua-router.py"

sys.path.insert(0, str(SCRIPTS_DIR))

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


if __name__ == "__main__":
    unittest.main()
