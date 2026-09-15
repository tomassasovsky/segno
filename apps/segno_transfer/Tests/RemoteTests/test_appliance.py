import importlib.util
import json
from pathlib import Path
import struct
import tempfile
import unittest
import sys
import subprocess

sys.dont_write_bytecode = True

HELPER = Path(__file__).parents[2] / "Sources/TransferCore/Resources/appliance.py"
spec = importlib.util.spec_from_file_location("appliance", HELPER)
appliance = importlib.util.module_from_spec(spec)
spec.loader.exec_module(appliance)


def wav(payload=b"\0" * 128):
    return (b"RIFF" + struct.pack("<I", len(payload) + 36) + b"WAVEfmt "
            + struct.pack("<IHHIIHH", 16, 3, 2, 48000, 384000, 8, 32)
            + b"data" + struct.pack("<I", len(payload)) + payload)


class ApplianceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.take = self.make_take("perf-20260915-144716")

    def make_take(self, name, finalized=True):
        directory = self.root / name
        directory.mkdir(parents=True)
        (directory / "performance.json").write_text(json.dumps({
            "slug": "perf-20260915-144716", "finalized": finalized,
            "sample_rate": 48000, "capture_frames": 96000}))
        (directory / "master.wav").write_bytes(wav())
        return directory

    def test_lists_complete_main_and_additional_files(self):
        (self.take / "live-input-0.wav").write_bytes(wav())
        result = appliance.catalog(self.root)
        self.assertEqual(result["unavailable"], 0)
        recording = result["recordings"][0]
        self.assertEqual(recording["duration"], 2)
        self.assertEqual(recording["timestamp"], "20260915144716")
        self.assertEqual([f["path"] for f in recording["files"]], ["master.wav", "live-input-0.wav"])

    def test_unfinished_and_corrupt_captures_are_unavailable(self):
        self.make_take("unfinished", finalized=False)
        bad = self.make_take("bad")
        (bad / "performance.json").write_text("{")
        result = appliance.catalog(self.root)
        self.assertEqual(result["unavailable"], 2)
        self.assertEqual(len(result["recordings"]), 1)

    def test_truncated_wav_is_not_offered(self):
        (self.take / "partial.wav").write_bytes(wav()[:-10])
        self.assertEqual(len(appliance.catalog(self.root)["recordings"][0]["files"]), 1)

    def test_recovered_take_and_renamed_folder_preserve_timestamp(self):
        self.make_take("recovered/renamed song")
        names = {r["id"]: r for r in appliance.catalog(self.root)["recordings"]}
        self.assertEqual(names["recovered/renamed song"]["timestamp"], "20260915144716")

    def test_symlinks_are_not_followed(self):
        (self.take / "linked.wav").symlink_to(self.take / "master.wav")
        (self.root / "alias").symlink_to(self.take, target_is_directory=True)
        result = appliance.catalog(self.root)
        self.assertEqual(len(result["recordings"]), 1)
        self.assertEqual(len(result["recordings"][0]["files"]), 1)
        with self.assertRaises(ValueError):
            appliance.safe_path(self.root, self.take.name + "/linked.wav")

    def test_path_traversal_rejected(self):
        for path in ("../outside", "/etc/passwd", "a/../b", "a//b", ""):
            with self.subTest(path=path), self.assertRaises(ValueError):
                appliance.safe_path(self.root, path)

    def test_stale_file_is_rejected(self):
        request = {"recording": self.take.name, "file": "master.wav",
                   "version": appliance.version(self.take / "master.wav")}
        (self.take / "master.wav").write_bytes(wav(b"\1" * 256))
        with self.assertRaisesRegex(ValueError, "changed"):
            appliance.selected_file(self.root, request)

    def test_hash_reads_exact_original(self):
        import hashlib
        source = self.take / "master.wav"
        request = {"root": str(self.root), "action": "hash", "recording": self.take.name,
                   "file": "master.wav", "version": appliance.version(source)}
        self.assertEqual(appliance.run(request)["sha256"], hashlib.sha256(source.read_bytes()).hexdigest())

    def test_read_ranges_are_exact_and_invalid_ranges_fail(self):
        source = self.take / "master.wav"
        command = [sys.executable, str(HELPER), "read", str(self.root), self.take.name,
                   "master.wav", appliance.version(source)]
        for offset, length in [(0, 2), (32, 16), (160, 12)]:
            output = subprocess.check_output(command + [str(offset), str(length)])
            self.assertEqual(output, source.read_bytes()[offset:offset + length])
        for offset, length in [(-1, 2), (0, 0), (0, 1048577), (172, 1), (171, 2)]:
            result = subprocess.run(command + [str(offset), str(length)], capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stdout, b"")

    def test_raw_pcm_cannot_be_requested_as_audio(self):
        source = self.take / "master.pcm"
        source.write_bytes(b"not a WAV")
        request = {"recording": self.take.name, "file": "master.pcm", "version": appliance.version(source)}
        with self.assertRaisesRegex(ValueError, "audio file"):
            appliance.selected_file(self.root, request)

    def test_incomplete_main_hides_whole_recording(self):
        (self.take / "master.wav").write_bytes(wav()[:44])
        result = appliance.catalog(self.root)
        self.assertEqual(result, {"recordings": [], "unavailable": 1})

    def test_bad_duration_does_not_hide_healthy_recordings(self):
        for name, frames in [("infinite", "1e400"), ("overflow", "1" + "0" * 400)]:
            bad = self.make_take(name)
            (bad / "performance.json").write_text('{"finalized":true,"sample_rate":1,"capture_frames":' + frames + '}')
        output = subprocess.check_output([sys.executable, str(HELPER), "catalog", str(self.root), "", "", ""])
        result = json.loads(output)
        self.assertEqual(len(result["recordings"]), 1)
        self.assertEqual(result["unavailable"], 2)

    def test_catalog_json_preserves_quotes_unicode_and_newlines_in_names(self):
        self.make_take("take 'quoted' café\nsecond line")
        output = subprocess.check_output([sys.executable, str(HELPER), "catalog", str(self.root), "", "", ""])
        result = json.loads(output)
        self.assertIn("take 'quoted' café\nsecond line", [r["name"] for r in result["recordings"]])

    def test_empty_catalog_emits_valid_json(self):
        empty = self.root / "empty"
        empty.mkdir()
        output = subprocess.check_output([sys.executable, str(HELPER), "catalog", str(empty), "", "", ""])
        self.assertEqual(json.loads(output), {"recordings": [], "unavailable": 0})


if __name__ == "__main__":
    unittest.main()
