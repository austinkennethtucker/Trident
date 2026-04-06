import importlib.util
import pathlib
import unittest


SCRIPT_PATH = pathlib.Path(__file__).with_name("update_homebrew_cask.py")
SPEC = importlib.util.spec_from_file_location("update_homebrew_cask", SCRIPT_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class UpdateHomebrewCaskTests(unittest.TestCase):
    def test_updates_stable_cask_version_sha_and_asset_id(self) -> None:
        original = """cask "trident" do
  version "v1.3.4"
  sha256 "oldsha"

  url "https://api.github.com/repos/subdepthtech/Trident/releases/assets/389041788",
      header: [
        "Accept: application/octet-stream",
        "Authorization: token #{ENV.fetch("HOMEBREW_GITHUB_API_TOKEN", "")}",
      ]
end
"""

        updated = MODULE.update_cask_text(
            original,
            version="v1.3.5",
            asset_id="400000001",
            sha256="newsha",
        )

        self.assertIn('version "v1.3.5"', updated)
        self.assertIn('sha256 "newsha"', updated)
        self.assertIn("releases/assets/400000001", updated)
        self.assertNotIn("releases/assets/389041788", updated)

    def test_updates_dev_cask_to_no_check_sha(self) -> None:
        original = """cask "trident-dev" do
  version "87ef6ce80"
  sha256 "oldsha"

  url "https://api.github.com/repos/subdepthtech/Trident/releases/assets/389042162",
      header: [
        "Accept: application/octet-stream",
        "Authorization: token #{ENV.fetch("HOMEBREW_GITHUB_API_TOKEN", "")}",
      ]
end
"""

        updated = MODULE.update_cask_text(
            original,
            version="149151339",
            asset_id="400000002",
            sha256=":no_check",
        )

        self.assertIn('version "149151339"', updated)
        self.assertIn("sha256 :no_check", updated)
        self.assertNotIn('sha256 "oldsha"', updated)
        self.assertIn("releases/assets/400000002", updated)

    def test_raises_when_expected_patterns_are_missing(self) -> None:
        with self.assertRaisesRegex(ValueError, "version"):
            MODULE.update_cask_text("cask \"trident\" do\nend\n", "v1.0.0", "123", "abc")


if __name__ == "__main__":
    unittest.main()
