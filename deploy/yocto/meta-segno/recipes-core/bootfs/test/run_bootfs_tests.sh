#!/usr/bin/env bash
# Tests for segno-bootfs.bb's do_compile — the code that turns IMAGE_BOOT_FILES
# into the tree the update bundle writes into a boot slot.
#
# It runs the recipe's actual python, lifted out of the .bb, against a fake
# DEPLOY_DIR_IMAGE shaped like meta-raspberrypi's — including the "bootfiles/*"
# glob that the real IMAGE_BOOT_FILES starts with. That entry is what broke
# 0.1.0-experimental.128/.129: the pattern's basename ("*") was used as the
# destination, so every firmware blob, config.txt and cmdline.txt landed on one
# file named "*", which vfat refused to create on the device. A Yocto build
# takes two hours and an install failure is only visible on a console, so this
# is the place to catch it.
#
# No bitbake needed: `d` and `bb` are stand-ins with just the surface the task
# uses. Run: bash deploy/yocto/meta-segno/recipes-core/bootfs/test/run_bootfs_tests.sh
set -u

here="$(cd "$(dirname "$0")" && pwd)"
recipe="$here/../segno-bootfs.bb"
[ -f "$recipe" ] || { echo "recipe not found: $recipe"; exit 1; }

RECIPE="$recipe" python3 - <<'PY'
import os, re, shutil, subprocess, sys, tarfile, tempfile, textwrap

recipe = open(os.environ["RECIPE"]).read()
m = re.search(r"^python do_compile\(\) \{\n(.*?)^\}\n", recipe, re.S | re.M)
assert m, "could not find python do_compile() in the recipe"
body = textwrap.dedent(m.group(1))


class Fatal(Exception):
    pass


class FakeUtils:
    @staticmethod
    def remove(path, recurse=False):
        if os.path.isdir(path):
            shutil.rmtree(path)
        elif os.path.exists(path):
            os.remove(path)


class FakeBB:
    utils = FakeUtils()

    @staticmethod
    def fatal(msg):
        raise Fatal(msg)

    @staticmethod
    def note(msg):
        pass


class FakeData:
    def __init__(self, vars):
        self.vars = vars

    def getVar(self, name):
        return self.vars.get(name)


def write(path, content=b""):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(content if isinstance(content, bytes) else content.encode())


def deploy_dir(root, cmdline="console=serial0,115200 root=XXX rootwait\n"):
    """A DEPLOY_DIR_IMAGE the way rpi-bootfiles, rpi-config, rpi-cmdline and
    the kernel leave it on a Pi 5 build."""
    dep = os.path.join(root, "deploy")
    write(os.path.join(dep, "bootfiles", "config.txt"), "dtoverlay=uart3-pi5\n")
    write(os.path.join(dep, "bootfiles", "cmdline.txt"), cmdline)
    write(os.path.join(dep, "bootfiles", "bootcode.bin"), b"\x00" * 64)
    write(os.path.join(dep, "bootfiles", "fixup.dat"), b"\x01" * 32)
    write(os.path.join(dep, "bootfiles", "start.elf"), b"\x02" * 128)
    write(os.path.join(dep, "bcm2712-rpi-5-b.dtb"), b"dtb")
    write(os.path.join(dep, "overlays", "uart3-pi5.dtbo"), b"dtbo")
    write(os.path.join(dep, "overlays", "vc4-kms-v3d-pi5.dtbo"), b"dtbo2")
    write(os.path.join(dep, "Image-raspberrypi5.bin"), b"kernel")
    return dep


# The shape of meta-raspberrypi's default: a bare glob, dtb renames, overlays
# into a directory, and the kernel renamed to what the firmware looks for.
BOOT_FILES = (
    "bootfiles/* "
    "bcm2712-rpi-5-b.dtb;bcm2712-rpi-5-b.dtb "
    "overlays/uart3-pi5.dtbo;overlays/uart3-pi5.dtbo "
    "overlays/vc4-kms-v3d-pi5.dtbo;overlays/vc4-kms-v3d-pi5.dtbo "
    "Image-raspberrypi5.bin;kernel_2712.img"
)


def run(root, boot_files=BOOT_FILES, **overrides):
    dep = os.path.join(root, "deploy")
    build = os.path.join(root, "build")
    vars = {
        "DEPLOY_DIR_IMAGE": dep,
        "B": build,
        "IMAGE_BOOT_FILES": boot_files,
        "SDIMG_KERNELIMAGE": "kernel_2712.img",
    }
    vars.update(overrides)
    exec(body, {"d": FakeData(vars), "bb": FakeBB(), "os": os, "shutil": shutil})
    return os.path.join(build, "bootfs")


def staged(bootfs):
    out = []
    for r, _d, files in os.walk(bootfs):
        for n in files:
            out.append(os.path.relpath(os.path.join(r, n), bootfs))
    return sorted(out)


passed = failed = 0


def check(name, cond, detail=""):
    global passed, failed
    if cond:
        passed += 1
        print(f"PASS: {name}")
    else:
        failed += 1
        print(f"FAIL: {name}" + (f" — {detail}" if detail else ""))


# --- a bare glob lands every match under its own name -----------------------
with tempfile.TemporaryDirectory() as root:
    deploy_dir(root)
    bootfs = run(root)
    got = staged(bootfs)
    check("no file is named after the glob pattern", "*" not in got and not any("*" in p for p in got), str(got))
    for name in ("config.txt", "cmdline.txt", "bootcode.bin", "fixup.dat", "start.elf"):
        check(f"bootfiles/* delivers {name} at the slot root", name in got, str(got))
    check("start.elf keeps its own content, not the last glob match's",
          open(os.path.join(bootfs, "start.elf"), "rb").read() == b"\x02" * 128)
    check("config.txt keeps its own content",
          open(os.path.join(bootfs, "config.txt")).read() == "dtoverlay=uart3-pi5\n")
    check("dtb rename lands at the root", "bcm2712-rpi-5-b.dtb" in got)
    check("overlays land inside overlays/", "overlays/uart3-pi5.dtbo" in got and "overlays/vc4-kms-v3d-pi5.dtbo" in got, str(got))
    check("kernel is renamed to what the firmware loads", "kernel_2712.img" in got and "Image-raspberrypi5.bin" not in got, str(got))

    # The exact command do_deploy runs, on the exact tree it would pack.
    tar_path = os.path.join(root, "bootfs.tar")
    subprocess.run(["tar", "-C", bootfs, "-cf", tar_path, "."], check=True)
    names = tarfile.open(tar_path).getnames()
    check("packed archive has no './*' entry", "./*" not in names, str(names))
    check("packed archive carries cmdline.txt", "./cmdline.txt" in names, str(names))

# --- a directory destination ("src;dir/") -----------------------------------
with tempfile.TemporaryDirectory() as root:
    deploy_dir(root)
    bootfs = run(root, boot_files=BOOT_FILES + " overlays/*;overlays/")
    got = staged(bootfs)
    check("glob into a directory keeps each match's name", "overlays/uart3-pi5.dtbo" in got and not any("*" in p for p in got), str(got))

# --- the build refuses a tree the device could not boot ----------------------
def fails_with(text, **kw):
    with tempfile.TemporaryDirectory() as root:
        deploy_dir(root, **{k: v for k, v in kw.items() if k == "cmdline"})
        try:
            run(root, **{k: v for k, v in kw.items() if k != "cmdline"})
        except Fatal as e:
            return text in str(e), str(e)
        return False, "did not fail"

ok, msg = fails_with("root=XXX", cmdline="console=serial0 root=/dev/nvme0n1p5 rootwait\n")
check("a cmdline.txt without the root=XXX placeholder fails the build", ok, msg)

ok, msg = fails_with("nothing", IMAGE_BOOT_FILES="")
check("an empty IMAGE_BOOT_FILES fails the build", ok, msg)

ok, msg = fails_with("nothing in", IMAGE_BOOT_FILES=BOOT_FILES + " pieeprom.upd")
check("an entry that matches nothing fails the build", ok, msg)

ok, msg = fails_with("missing config.txt",
                     IMAGE_BOOT_FILES="bootfiles/cmdline.txt Image-raspberrypi5.bin;kernel_2712.img")
check("a slot without config.txt fails the build", ok, msg)

ok, msg = fails_with("missing the kernel image",
                     IMAGE_BOOT_FILES="bootfiles/*")
check("a slot without the kernel fails the build", ok, msg)

print(f"\n{passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
PY
