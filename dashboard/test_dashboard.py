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
            if cmd == ["pgrep", "-P", "7240"]:
                return "7241\n"
            if cmd == ["ps", "-o", "comm=", "-p", "7241"]:
                return "codex\n"
            raise AssertionError(f"unexpected command: {cmd}")

        with patch.object(dashboard_module.subprocess, "check_output", side_effect=fake_check_output):
            self.assertTrue(dashboard_module._agent_process_alive(7240, "-zsh", "codex"))

    def test_accepts_direct_variant_process_name(self) -> None:
        # pane command itself matches backend — no subprocess calls needed
        self.assertTrue(dashboard_module._agent_process_alive(9159, "codex-aarch64-a", "codex"))

    def test_returns_false_when_expected_process_missing(self) -> None:
        def fake_check_output(cmd, text=True, stderr=None):
            if cmd == ["pgrep", "-P", "1000"]:
                return "2000\n3000\n"
            if cmd == ["ps", "-o", "comm=", "-p", "2000"]:
                return "python\n"
            if cmd == ["ps", "-o", "comm=", "-p", "3000"]:
                return "tmux\n"
            raise AssertionError(f"unexpected command: {cmd}")

        with patch.object(dashboard_module.subprocess, "check_output", side_effect=fake_check_output):
            self.assertFalse(dashboard_module._agent_process_alive(1000, "-zsh", "codex"))


if __name__ == "__main__":
    unittest.main()
