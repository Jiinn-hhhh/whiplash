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


class ParseSessionsMdTest(unittest.TestCase):
    def _sessions_md_content(self, rows: list[str]) -> str:
        header = "| 역할 | 백엔드 | 세션ID | tmux대상 | 상태 | 시작일 | 모델 |"
        sep = "| --- | --- | --- | --- | --- | --- | --- |"
        return "\n".join([header, sep] + rows)

    def test_parses_valid_row(self) -> None:
        content = self._sessions_md_content([
            "| developer | claude | s1 | whiplash-p:dev | active | 2025-01-01 | claude-3 |",
        ])
        with patch.object(dashboard_module, "_read_file", return_value=content):
            agents = dashboard_module.parse_sessions_md("/fake/project")
        self.assertEqual(len(agents), 1)
        self.assertEqual(agents[0]["role"], "developer")

    def test_drops_row_with_fewer_than_7_cols_and_warns(self) -> None:
        content = self._sessions_md_content([
            "| developer | claude | s1 | whiplash-p:dev | active |",  # only 5 cols
        ])
        import io
        with patch.object(dashboard_module, "_read_file", return_value=content):
            with patch("sys.stderr", new_callable=io.StringIO) as mock_err:
                agents = dashboard_module.parse_sessions_md("/fake/project")
                warning = mock_err.getvalue()
        self.assertEqual(agents, [])
        self.assertIn("sessions.md", warning)

    def test_deduplicates_by_tmux_target(self) -> None:
        content = self._sessions_md_content([
            "| developer | claude | s1 | whiplash-p:dev | active | 2025-01-01 | claude-3 |",
            "| developer | claude | s2 | whiplash-p:dev | active | 2025-01-02 | claude-3 |",
        ])
        with patch.object(dashboard_module, "_read_file", return_value=content):
            agents = dashboard_module.parse_sessions_md("/fake/project")
        self.assertEqual(len(agents), 1)
        self.assertEqual(agents[0]["session_id"], "s2")


class CellLenTest(unittest.TestCase):
    def test_ascii_only(self) -> None:
        self.assertEqual(dashboard_module.cell_len("hello"), 5)

    def test_korean_chars_count_as_two(self) -> None:
        # "안녕" = 2 Korean chars → display width 4
        self.assertEqual(dashboard_module.cell_len("안녕"), 4)

    def test_mixed_ascii_and_korean(self) -> None:
        # "Hi안녕" = 2 ASCII (2) + 2 Korean (4) = 6
        self.assertEqual(dashboard_module.cell_len("Hi안녕"), 6)

    def test_empty_string(self) -> None:
        self.assertEqual(dashboard_module.cell_len(""), 0)


if __name__ == "__main__":
    unittest.main()
