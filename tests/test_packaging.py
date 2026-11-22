import os
import re
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..")


def read(*path):
    with open(os.path.join(ROOT, *path), encoding="utf-8") as f:
        return f.read()


class GhosttyVtPins(unittest.TestCase):
    """libghostty-vt and its Zig are pinned twice: in the PKGBUILD (makepkg downloads and checks
    them) and in native/ghostty-vt/build.sh (which builds them, for the package and for a build from
    the checkout). Both must name the same versions and hashes."""

    def setUp(self):
        self.pkgbuild = read("packaging", "arch", "PKGBUILD")
        self.script = read("native", "ghostty-vt", "build.sh")

    def pkg(self, name):
        return re.search(rf"^{name}=(\S+)$", self.pkgbuild, re.M).group(1)

    def test_the_same_versions(self):
        self.assertEqual(self.pkg("_zigver"), re.search(r"^ZIG_VERSION=(\S+)$", self.script, re.M).group(1))
        self.assertEqual(self.pkg("_ghosttyvtver"),
                         re.search(r"^GHOSTTY_VT_VERSION=(\S+)$", self.script, re.M).group(1))

    def test_the_same_hashes(self):
        script = dict(re.findall(r"^\s*\[([^\]]+)\]=([0-9a-f]{64})$", self.script, re.M))
        zig, vt = self.pkg("_zigver"), self.pkg("_ghosttyvtver")
        sums = lambda key: re.findall(r"'([0-9a-f]{64}|SKIP)'", re.search(
            rf"^{key}=\(([^)]*)\)", self.pkgbuild, re.M | re.S).group(1))
        self.assertEqual(sums("sha256sums"), ["SKIP", script[f"libghostty-vt-{vt}.tar.gz"],
                                              script[f"libghostty-vt-{vt}-deps.tar.gz"]])
        for arch in ("x86_64", "aarch64"):
            self.assertEqual(sums(f"sha256sums_{arch}"), [script[f"zig-{arch}-linux-{zig}.tar.xz"]])
        self.assertEqual(len(script), 4)

    def test_the_package_carries_its_licence(self):
        self.assertIn("libghostty-vt-LICENSE", self.pkgbuild)


if __name__ == "__main__":
    unittest.main()
