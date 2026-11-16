"""Unit tests for the in-guest detector's record parsing and rules. No cluster needed:

    python3 tests/test_guest_detector.py
"""
import importlib.util
import pathlib
import unittest

spec = importlib.util.spec_from_file_location(
    "guest_detector", pathlib.Path(__file__).parent.parent / "deploy" / "guest-detector.py")
gd = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gd)

API = ("10.100.0.1", 443)
KEY = 'key="runtime-detection"'


def event(*records):
    """Build an event the way main() does, from (type, text) pairs."""
    out = {}
    for msg_type, text in records:
        out.setdefault(msg_type, []).append(gd.parse("audit(1.0:7): " + text)[1])
    return out


class ParseTest(unittest.TestCase):
    def test_numbers_stay_numbers(self):
        # "59" is also valid hex; it must not be decoded as the string "Y".
        _, fields = gd.parse('audit(1.0:7): syscall=59 comm="sh"')
        self.assertEqual(fields["syscall"], "59")

    def test_hex_encoded_name_is_decoded(self):
        _, fields = gd.parse("audit(1.0:7): name=2F746D702F612062")  # "/tmp/a b"
        self.assertEqual(fields["name"], "/tmp/a b")


class ClassifyTest(unittest.TestCase):
    def test_terminal_shell(self):
        ev = event((1300, f'syscall=59 success=yes tty=pts0 exe="/usr/bin/dash" {KEY}'))
        self.assertEqual([a[0] for a in gd.classify(ev, API, set())], ["Terminal shell in container"])

    def test_shell_without_terminal_is_quiet(self):
        ev = event((1300, f'syscall=59 success=yes tty=(none) exe="/usr/bin/dash" {KEY}'))
        self.assertEqual(gd.classify(ev, API, set()), [])

    def test_shadow_read_and_write(self):
        read = event((1300, f"syscall=257 success=yes a2=0 {KEY}"), (1307, 'cwd="/"'),
                     (1302, 'name="/etc/shadow" nametype=NORMAL'))
        self.assertEqual([a[0] for a in gd.classify(read, API, set())], ["Read sensitive file untrusted"])
        write = event((1300, f"syscall=257 success=yes a2=241 {KEY}"), (1307, 'cwd="/"'),
                      (1302, 'name="/etc/shadow" nametype=NORMAL'))
        self.assertEqual(gd.classify(write, API, set()), [])

    def test_exec_of_written_file(self):
        written = set()
        create = event((1300, f"syscall=257 success=yes a2=241 {KEY}"), (1307, 'cwd="/tmp"'),
                       (1302, 'name="x" nametype=CREATE'))
        gd.classify(create, API, written)
        run = event((1300, f'syscall=59 success=yes tty=(none) exe="/tmp/x" {KEY}'))
        self.assertEqual([a[0] for a in gd.classify(run, API, written)],
                         ["Drop and execute new binary in container"])
        other = event((1300, f'syscall=59 success=yes tty=(none) exe="/usr/bin/cat" {KEY}'))
        self.assertEqual(gd.classify(other, API, written), [])

    def test_connect_in_progress_to_api_server(self):
        ev = event((1300, f"syscall=42 success=no exit=-115 {KEY}"),
                   (1306, "saddr=020001BB0A6400010000000000000000"))
        self.assertEqual([a[0] for a in gd.classify(ev, API, set())],
                         ["Contact K8S API Server From Container"])
        elsewhere = event((1300, f"syscall=42 success=no exit=-115 {KEY}"),
                          (1306, "saddr=020001BB0A6400020000000000000000"))
        self.assertEqual(gd.classify(elsewhere, API, set()), [])

    def test_other_key_is_ignored(self):
        ev = event((1300, 'syscall=59 success=yes tty=pts0 exe="/usr/bin/dash" key="other"'))
        self.assertEqual(gd.classify(ev, API, set()), [])


if __name__ == "__main__":
    unittest.main()
