import importlib.util
import unittest
from pathlib import Path
from unittest.mock import patch


MODULE_PATH = Path(__file__).with_name("dashboard.py")
SPEC = importlib.util.spec_from_file_location("dashboard_module", MODULE_PATH)
dashboard_module = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(dashboard_module)


class DashboardProcessAliveTest(unittest.TestCase):
    def test_detects_codex_child_under_shell_pane(self) -> None:
        def fake_check_output(cmd, text=True, stderr=None):
            if cmd == ["ps", "-p", "7240", "-o", "comm="]:
                return "-zsh\n"
            if cmd == ["ps", "-axo", "ppid=,comm="]:
                return "7240 codex\n8191 claude\n"
            raise AssertionError(f"unexpected command: {cmd}")

        with patch.object(dashboard_module.subprocess, "check_output", side_effect=fake_check_output):
            self.assertTrue(dashboard_module._agent_process_alive(7240, "codex"))

    def test_accepts_direct_variant_process_name(self) -> None:
        def fake_check_output(cmd, text=True, stderr=None):
            if cmd == ["ps", "-p", "9159", "-o", "comm="]:
                return "codex-aarch64-a\n"
            raise AssertionError(f"unexpected command: {cmd}")

        with patch.object(dashboard_module.subprocess, "check_output", side_effect=fake_check_output):
            self.assertTrue(dashboard_module._agent_process_alive(9159, "codex"))

    def test_returns_false_when_expected_process_missing(self) -> None:
        def fake_check_output(cmd, text=True, stderr=None):
            if cmd == ["ps", "-p", "1000", "-o", "comm="]:
                return "-zsh\n"
            if cmd == ["ps", "-axo", "ppid=,comm="]:
                return "2000 python\n3000 tmux\n"
            raise AssertionError(f"unexpected command: {cmd}")

        with patch.object(dashboard_module.subprocess, "check_output", side_effect=fake_check_output):
            self.assertFalse(dashboard_module._agent_process_alive(1000, "codex"))


if __name__ == "__main__":
    unittest.main()
