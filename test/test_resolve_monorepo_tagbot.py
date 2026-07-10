import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = (
    Path(__file__).parents[1]
    / ".github"
    / "actions"
    / "resolve-monorepo-tagbot"
    / "resolve.py"
)
SPEC = importlib.util.spec_from_file_location("resolve_monorepo_tagbot", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class ResolverTests(unittest.TestCase):
    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        self.workspace = Path(self.tempdir.name)
        self.write_project("Project.toml", "Umbrella")
        self.write_project("lib/Foo/Project.toml", "Foo")
        self.write_project("lib/Bar/Project.toml", "Bar")

    def tearDown(self):
        self.tempdir.cleanup()

    def write_project(self, relative_path, name):
        path = self.workspace / relative_path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(f'name = "{name}"\n', encoding="utf-8")

    def test_registry_pr_routes_only_matching_subpackage(self):
        body = (
            "Triggering TagBot for merged registry pull request: "
            "https://github.com/JuliaRegistries/General/pull/123"
        )
        seen = []

        def fetch_pr(number, token):
            seen.append((number, token))
            return {"title": "New version: Foo v1.2.3"}

        result = MODULE.resolve(self.workspace, body, "", "token", fetch_pr)

        self.assertEqual(result.subdirs, ["lib/Foo"])
        self.assertEqual(result.mode, "registry-pr")
        self.assertEqual(result.package, "Foo")
        self.assertEqual(result.version, "1.2.3")
        self.assertEqual(seen, [(123, "token")])

    def test_registry_pr_routes_root_package(self):
        result = MODULE.resolve(
            self.workspace,
            "https://github.com/JuliaRegistries/General/pull/42",
            "",
            "token",
            lambda number, token: {"title": "New version: Umbrella v2.0.0"},
        )

        self.assertEqual(result.subdirs, [""])
        self.assertEqual(result.package, "Umbrella")

    def test_retry_comment_without_pr_runs_ordered_full_audit(self):
        result = MODULE.resolve(
            self.workspace,
            "This extra notification is being sent because I expected a tag to exist by now.",
            "",
            "token",
        )

        self.assertEqual(result.mode, "full-audit")
        self.assertEqual(result.subdirs, ["", "lib/Bar", "lib/Foo"])

    def test_manual_package_routes_one_package(self):
        result = MODULE.resolve(self.workspace, "", "Bar", "token")

        self.assertEqual(result.mode, "manual")
        self.assertEqual(result.package, "Bar")
        self.assertEqual(result.subdirs, ["lib/Bar"])

    def test_empty_manual_package_runs_full_audit(self):
        result = MODULE.resolve(self.workspace, "", "", "token")

        self.assertEqual(result.mode, "full-audit")
        self.assertEqual(len(result.subdirs), 3)

    def test_unknown_registered_package_fails(self):
        with self.assertRaisesRegex(MODULE.ResolutionError, "was not found"):
            MODULE.resolve(
                self.workspace,
                "https://github.com/JuliaRegistries/General/pull/42",
                "",
                "token",
                lambda number, token: {"title": "New version: Missing v1.0.0"},
            )

    def test_unknown_manual_package_fails(self):
        with self.assertRaisesRegex(MODULE.ResolutionError, "manual package"):
            MODULE.resolve(self.workspace, "", "Missing", "token")

    def test_unexpected_general_pr_title_fails(self):
        with self.assertRaisesRegex(MODULE.ResolutionError, "unexpected General"):
            MODULE.resolve(
                self.workspace,
                "https://github.com/JuliaRegistries/General/pull/42",
                "",
                "token",
                lambda number, token: {"title": "Update Versions.toml"},
            )

    def test_multiple_general_pr_links_fail(self):
        with self.assertRaisesRegex(MODULE.ResolutionError, "multiple General"):
            MODULE.resolve(
                self.workspace,
                "https://github.com/JuliaRegistries/General/pull/1 "
                "https://github.com/JuliaRegistries/General/pull/2",
                "",
                "token",
            )


if __name__ == "__main__":
    unittest.main()
