#!/usr/bin/env python3
"""隔离测试统一入口：模拟系统/网络/安装器，不安装真实工具。"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
THEOS_FILES = [
    "makefiles/common.mk", "makefiles/aggregate.mk", "makefiles/application.mk",
    "makefiles/tweak.mk", "vendor/logos/bin/logos.pl", "vendor/include/substrate.h",
]
DEPS_FILES = [
    "Engine/lib/arm64/libQBDI.a", "Engine/lib/arm64/libdobby.a",
    "Engine/include/QBDI.h", "Engine/include/dobby.h", "Engine/include/QBDI/Config.h",
    "Engine/include/QBDI/Version.h", "Engine/include/QBDI/Options.h", "Engine/include/QBDI/State.h",
]
DRIVER = r'''import json, os, pathlib, sys
base = pathlib.Path(os.environ["FIXTURE"])
config = json.loads((base / "config.json").read_text())
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with (base / "calls.log").open("a") as f:
    f.write(json.dumps([name] + args) + "\n")
if name == "uname":
    print(config.get("os", "Darwin"))
elif name == "id":
    print(config.get("uid", 501))
elif name == "xcode-select":
    print(config.get("selected", str(base / "Xcode.app/Contents/Developer")))
elif name == "xcrun":
    if config.get("sdk_failure"):
        sys.exit(1)
    print(base / "sdk" if "--show-sdk-path" in args else "/usr/bin/clang")
elif name == "xcodebuild":
    sys.exit(1 if config.get("first_launch_failure") else 0)
elif name == "curl":
    if config.get("offline"):
        sys.exit(28)
    if config.get("download_failure") and "https://github.com/" not in args:
        sys.exit(22)
    target = pathlib.Path(args[args.index("--output") + 1])
    if target != pathlib.Path("/dev/null"):
        if "install-homebrew.sh" in target.name:
            # 模拟官方安装器创建 brew，不调用真实 Homebrew。
            target.write_text('mkdir -p "$FIXTURE/brew-prefix/bin"\nln -s "$FIXTURE/driver" "$FIXTURE/brew-prefix/bin/brew"\n')
        else:
            if config.get("theos_failure"):
                target.write_text("exit 9\n")
            else:
                target.write_text("#!/bin/bash\n" + "\n".join(
                    'mkdir -p "$THEOS/' + str(pathlib.Path(f).parent) + '"; printf x > "$THEOS/' + f + '"'
                    for f in config["theos_files"]) + "\n")
elif name == "brew":
    if config.get("brew_failure"):
        sys.exit(1)
    if args and args[0] == "install":
        for formula in args[1:]:
            tool = "python3" if formula == "python" else formula
            (base / ("installed-" + tool)).touch()
            link = base / "bin" / tool
            if not link.exists():
                link.symlink_to(base / "driver")
elif name == "git" and args and args[0] == "clone":
    dest = pathlib.Path(args[-1])
    for f in config["theos_files"]:
        target = dest / f
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text("fixture")
elif name in ("git", "cmake", "ninja", "python3", "xz", "ldid"):
    if name in config.get("missing", []) and not (base / ("installed-" + name)).exists():
        sys.exit(1)
    print("mock version")
else:
    sys.exit("unexpected mocked command: " + name)
'''


def put_files(base, names):
    for name in names:
        target = base / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text("fixture")


class SetupTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="qbdi-setup-test-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        (self.base / "bin").mkdir()
        (self.base / "scripts").mkdir()
        (self.base / "sdk").mkdir()
        (self.base / "Xcode.app/Contents/Developer").mkdir(parents=True)
        self.driver = self.base / "driver"
        self.driver.write_text("#!" + sys.executable + "\n" + DRIVER)
        self.driver.chmod(0o755)
        for name in ("uname", "id", "xcode-select", "xcrun", "xcodebuild", "curl",
                     "brew", "git", "cmake", "ninja", "python3", "xz", "ldid"):
            (self.base / "bin" / name).symlink_to(self.driver)
        # 将固定的系统搜索目录映射进沙箱，防止读取宿主机 Homebrew / Xcode。
        source = (ROOT / "scripts/setup_and_build.sh").read_text()
        source = source.replace("/Applications/Xcode.app", str(self.base / "Xcode.app"))
        source = source.replace("/opt/homebrew", str(self.base / "brew-prefix"))
        source = source.replace("/usr/local", str(self.base / "unused-prefix"))
        self.script = self.base / "scripts/setup_and_build.sh"
        self.script.write_text(source)
        self.theos = self.base / "theos"
        put_files(self.theos, THEOS_FILES)
        put_files(self.base, DEPS_FILES)
        (self.base / "scripts/build_debs.sh").write_text(
            'printf "build:%s\\n" "$*" >> "$FIXTURE/children.log"\n'
            '[ "$THEOS_PLATFORM_SDK_ROOT" = "$DEVELOPER_DIR" ] || exit 19\n'
            'exit "${BUILD_EXIT:-0}"\n')
        (self.base / "scripts/build_deps_ios.sh").write_text(
            'echo deps >> "$FIXTURE/children.log"\n'
            'if [ "${DEPS_EXIT:-0}" != 0 ]; then exit "$DEPS_EXIT"; fi\n' + "\n".join(
                'mkdir -p "' + str((self.base / f).parent) + '"; printf x > "' + str(self.base / f) + '"'
                for f in DEPS_FILES) + "\n")

    def run_script(self, args=(), config=None, extra_env=None):
        settings = {"theos_files": THEOS_FILES}
        settings.update(config or {})
        (self.base / "config.json").write_text(json.dumps(settings))
        env = os.environ.copy()
        env.pop("DEVELOPER_DIR", None)
        env.update(PATH=str(self.base / "bin") + ":/usr/bin:/bin",
                   HOME=str(self.base), THEOS=str(self.theos), FIXTURE=str(self.base))
        env.update(extra_env or {})
        self.result = subprocess.run(["/bin/bash", str(self.script), *args], env=env,
                                     text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        return self.result

    def children(self):
        path = self.base / "children.log"
        return path.read_text() if path.exists() else ""

    def calls(self):
        path = self.base / "calls.log"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def assert_ok(self, result):
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_check_read_only(self):
        self.assert_ok(self.run_script(["--check"]))
        self.assertEqual(self.children(), "")
        self.assertFalse(any(call[0] == "brew" for call in self.calls()))

    def test_check_reports_missing_and_offline_without_installing(self):
        result = self.run_script(["--check"], {"missing": ["cmake", "python3"], "offline": True})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("cmake", result.stdout)
        self.assertIn("python3", result.stdout)
        self.assertEqual(self.children(), "")
        self.assertFalse(any(call[0] == "brew" for call in self.calls()))

    def test_release_reuses_deps_and_accepts_spaces_in_existing_theos(self):
        dest = self.base / "existing theos"
        self.theos.rename(dest)
        self.assert_ok(self.run_script(["--release"], extra_env={"THEOS": str(dest)}))
        self.assertEqual(self.children(), "build:--release\n")
        self.assertFalse(any(call[0] == "brew" for call in self.calls()))

    def test_offline_cached_build(self):
        self.assert_ok(self.run_script(config={"offline": True}))
        self.assertEqual(self.children(), "build:\n")

    def test_missing_tools_install_then_recheck(self):
        self.assert_ok(self.run_script(["--setup-only"], {"missing": ["cmake", "python3"]}))
        self.assertIn(["brew", "install", "cmake", "python"], self.calls())
        self.assertEqual(self.children(), "")

    def test_brew_failure_stops_before_build(self):
        result = self.run_script(config={"missing": ["ninja"], "brew_failure": True})
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.children(), "")

    def test_installs_homebrew_and_theos(self):
        (self.base / "bin/brew").unlink()
        shutil.rmtree(self.theos)
        self.assert_ok(self.run_script(["--setup-only"]))
        self.assertTrue((self.theos / "vendor/include/substrate.h").is_file())
        self.assertTrue((self.base / "brew-prefix/bin/brew").exists())
        self.assertEqual(self.children(), "")

    def test_partial_theos_is_preserved(self):
        marker = self.theos / "user-file"
        marker.write_text("keep me")
        (self.theos / "vendor/include/substrate.h").unlink()
        result = self.run_script(["--setup-only"])
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(marker.read_text(), "keep me")
        self.assertFalse(any(call[:2] == ["git", "clone"] for call in self.calls()))

    def test_missing_header_rebuilds_dependencies(self):
        (self.base / "Engine/include/QBDI/Config.h").unlink()
        self.assert_ok(self.run_script(["--release"]))
        self.assertEqual(self.children(), "deps\nbuild:--release\n")

    def test_dependency_failure_stops_packaging(self):
        (self.base / "Engine/lib/arm64/libdobby.a").unlink()
        result = self.run_script(extra_env={"DEPS_EXIT": "7"})
        self.assertEqual(result.returncode, 7, result.stdout)
        self.assertEqual(self.children(), "deps\n")

    def test_crlf_child_scripts_are_repaired_before_running(self):
        for name in ("build_deps_ios.sh", "build_debs.sh"):
            path = self.base / "scripts" / name
            path.write_bytes(path.read_bytes().replace(b"\n", b"\r\n"))
        (self.base / "Engine/lib/arm64/libdobby.a").unlink()
        self.assert_ok(self.run_script(["--release"]))
        self.assertEqual(self.children(), "deps\nbuild:--release\n")
        for name in ("build_deps_ios.sh", "build_debs.sh"):
            self.assertNotIn(b"\r", (self.base / "scripts" / name).read_bytes())

    def test_check_does_not_repair_crlf_scripts(self):
        path = self.base / "scripts/build_debs.sh"
        original = path.read_bytes().replace(b"\n", b"\r\n")
        path.write_bytes(original)
        self.assert_ok(self.run_script(["--check"]))
        self.assertEqual(path.read_bytes(), original)

    def test_xcode_failure_stops_before_download(self):
        result = self.run_script(config={"first_launch_failure": True})
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(call[0] == "curl" for call in self.calls()))

    def test_clt_selection_uses_default_xcode(self):
        self.assert_ok(self.run_script(["--check"], {"selected": "/Library/Developer/CommandLineTools"}))
        self.assertIn(str(self.base / "Xcode.app/Contents/Developer"), self.result.stdout)

    def test_download_failure_stops(self):
        (self.base / "bin/brew").unlink()
        result = self.run_script(config={"missing": ["ninja"], "download_failure": True})
        self.assertEqual(result.returncode, 22, result.stdout)
        self.assertEqual(self.children(), "")

    def test_packaging_failure_propagates(self):
        self.assertEqual(self.run_script(extra_env={"BUILD_EXIT": "8"}).returncode, 8)

    def test_invalid_args_platform_and_root(self):
        for args, config in [(["--unknown"], {}), (["--check", "--setup-only"], {}),
                             ([], {"os": "Linux"}), ([], {"uid": 0})]:
            with self.subTest(args=args, config=config):
                self.assertNotEqual(self.run_script(args, config).returncode, 0)
        self.assertEqual(self.children(), "")


class BuildDebsLineEndingTest(unittest.TestCase):
    def test_control_is_normalized_before_first_make(self):
        control_lf = (ROOT / "control").read_bytes()
        for ending in (b"\n", b"\r\n", b"\r"):
            with self.subTest(ending=ending), tempfile.TemporaryDirectory(prefix="qbdi-control-test-") as temp:
                base = Path(temp)
                (base / "scripts").mkdir()
                (base / "bin").mkdir()
                shutil.copyfile(ROOT / "scripts/build_debs.sh", base / "scripts/build_debs.sh")
                control = base / "control"
                control.write_bytes(control_lf.replace(b"\n", ending))
                make = base / "bin/make"
                make.write_text("#!" + sys.executable + "\n" + r'''import os, pathlib, sys
root = pathlib.Path.cwd()
assert b"\r" not in (root / "control").read_bytes(), "control must be fixed before make"
with (root / "make.log").open("a") as log:
    log.write(" ".join(sys.argv[1:]) + "\n")
if "package" in sys.argv:
    arch = "iphoneos-arm64" if os.environ.get("THEOS_PACKAGE_SCHEME") == "rootless" else "iphoneos-arm"
    version = next(a.split("=", 1)[1] for a in sys.argv if a.startswith("PACKAGE_VERSION="))
    (root / "packages").mkdir(exist_ok=True)
    (root / "packages" / f"com.snk.qbditracer_{version}_{arch}.deb").write_text("fixture")
''')
                make.chmod(0o755)
                env = os.environ.copy()
                env.update(PATH=str(base / "bin") + ":/usr/bin:/bin", THEOS=str(base / "theos"))
                result = subprocess.run(["/bin/sh", str(base / "scripts/build_debs.sh"), "--release"],
                                        env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
                self.assertEqual(result.returncode, 0, result.stdout)
                self.assertEqual(control.read_bytes(), control_lf)
                self.assertEqual(len(list((base / "packages").glob("*.deb"))), 2)
                calls = (base / "make.log").read_text().splitlines()
                self.assertEqual(len(calls), 4)  # clean + package for each scheme
                for line in calls:
                    if "THEOS_STAGING_DIR=" in line:
                        stage = line.split("THEOS_STAGING_DIR=", 1)[1].split()[0]
                        self.assertFalse(Path(stage).parent.exists(), "temporary staging must be cleaned")


if __name__ == "__main__":
    unittest.main(verbosity=2)
