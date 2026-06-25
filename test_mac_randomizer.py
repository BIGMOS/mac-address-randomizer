"""
Tests for mac_randomizer.py — no admin rights or network adapter required.
Run with: python -m pytest test_mac_randomizer.py -v
"""

import re
import sys
import unittest
from unittest.mock import MagicMock, patch

# Stub winreg so the module can be imported on non-Windows or without admin
sys.modules.setdefault("winreg", MagicMock())

import mac_randomizer  # noqa: E402  (import after stub)


class TestRandomMac(unittest.TestCase):

    def test_format(self):
        mac = mac_randomizer.random_mac()
        self.assertRegex(mac, r"^[0-9A-F]{12}$", "Must be 12 uppercase hex chars")

    def test_locally_administered_bit(self):
        for _ in range(200):
            mac = mac_randomizer.random_mac()
            first_byte = int(mac[:2], 16)
            # Bit 1 (0x02) must be set, bit 0 (0x01) must be clear
            self.assertEqual(first_byte & 0x03, 0x02,
                             f"First byte {first_byte:#04x} violates LA-unicast rule")

    def test_uniqueness(self):
        macs = {mac_randomizer.random_mac() for _ in range(500)}
        self.assertGreater(len(macs), 490, "Expected near-unique MACs in 500 samples")

    def test_length_always_12(self):
        for _ in range(100):
            self.assertEqual(len(mac_randomizer.random_mac()), 12)


class TestIsAdmin(unittest.TestCase):

    def test_returns_bool(self):
        with patch("ctypes.windll.shell32.IsUserAnAdmin", return_value=1):
            self.assertTrue(mac_randomizer.is_admin())
        with patch("ctypes.windll.shell32.IsUserAnAdmin", return_value=0):
            self.assertFalse(mac_randomizer.is_admin())

    def test_exception_returns_false(self):
        with patch("ctypes.windll.shell32.IsUserAnAdmin", side_effect=OSError):
            self.assertFalse(mac_randomizer.is_admin())


class TestGetCurrentMac(unittest.TestCase):

    def _run(self, stdout):
        mock_result = MagicMock()
        mock_result.stdout = stdout
        with patch("subprocess.run", return_value=mock_result):
            return mac_randomizer.get_current_mac("Wi-Fi")

    def test_parses_hyphenated_mac(self):
        mac = self._run("02-AB-CD-EF-12-34\n")
        self.assertEqual(mac, "02ABCDEF1234")

    def test_empty_returns_none(self):
        self.assertIsNone(self._run(""))

    def test_strips_whitespace(self):
        mac = self._run("  02AABBCCDDEE  \n")
        self.assertEqual(mac, "02AABBCCDDEE")


class TestRotateMacLogic(unittest.TestCase):

    def test_rotate_aborts_if_no_registry_key(self):
        with patch.object(mac_randomizer, "find_adapter_registry_key", return_value=None):
            result = mac_randomizer.rotate_mac("Wi-Fi")
        self.assertFalse(result)

    def test_rotate_aborts_if_disable_fails(self):
        with patch.object(mac_randomizer, "find_adapter_registry_key", return_value="0001"), \
             patch.object(mac_randomizer, "set_adapter_state", return_value=False):
            result = mac_randomizer.rotate_mac("Wi-Fi")
        self.assertFalse(result)

    def test_rotate_success_path(self):
        with patch.object(mac_randomizer, "find_adapter_registry_key", return_value="0001"), \
             patch.object(mac_randomizer, "set_adapter_state", return_value=True), \
             patch.object(mac_randomizer, "write_mac_to_registry", return_value=True), \
             patch.object(mac_randomizer, "get_current_mac", return_value=None), \
             patch("time.sleep"):
            result = mac_randomizer.rotate_mac("Wi-Fi")
        self.assertTrue(result)


if __name__ == "__main__":
    unittest.main()
