import os
from pathlib import Path
import subprocess
import tempfile
import unittest


CTL = Path(__file__).with_name("ctl.sh")
CORE = ("mihomo-codex", "backend", "frontend")
MOCKS = r'''
launchctl() {
  printf 'launchctl %s\n' "$*" >> "$MOCK_TRACE"
  if [[ "$1" == print ]]; then return "${MOCK_NOT_LOADED:-0}"; fi
  if [[ "$1" == bootout ]]; then return "${MOCK_BOOTOUT_FAILURE:-0}"; fi
  return 0
}
brew() { printf 'brew %s\n' "$*" >> "$MOCK_TRACE"; }
nc() { [[ "${@: -1}" != "${MOCK_OFFLINE_PORT:-none}" ]]; }
curl() { printf 'curl %s\n' "$*" >> "$MOCK_TRACE"; return 0; }
sleep() { :; }
'''


class LaunchdControlTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.agents = self.home / "Library" / "LaunchAgents"
        self.agents.mkdir(parents=True)
        for name in CORE:
            (self.agents / f"com.mrack.sub2api.{name}.plist").touch()
        self.mock = self.home / "mocks.sh"
        self.mock.write_text(MOCKS)
        self.trace = self.home / "trace"

    def invoke(self, command, **overrides):
        env = dict(os.environ, HOME=str(self.home), BASH_ENV=str(self.mock),
                   MOCK_TRACE=str(self.trace), SUB2_ENABLE_LEGACY_SERVICES="0")
        env.update(overrides)
        result = subprocess.run(["/bin/bash", str(CTL), command], env=env,
                                text=True, capture_output=True, timeout=5)
        trace = self.trace.read_text() if self.trace.exists() else ""
        return result, trace

    def test_status_includes_sidecar_and_bypasses_environment_proxy(self):
        result, trace = self.invoke("status")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("com.mrack.sub2api.mihomo-codex: loaded", result.stdout)
        self.assertIn("3101", result.stdout)
        self.assertIn("--noproxy *", trace)
        self.assertNotIn("com.mrack.sub2api.clash", trace)
        self.assertNotIn("com.mrack.sub2api.mock", trace)

    def test_start_only_needs_core_plists(self):
        result, trace = self.invoke("start", MOCK_NOT_LOADED="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        bootstraps = [line for line in trace.splitlines() if " bootstrap " in line]
        self.assertEqual(len(bootstraps), 3)
        for line, name in zip(bootstraps, CORE):
            self.assertIn(f"com.mrack.sub2api.{name}.plist", line)
        self.assertNotIn("kickstart -k", trace)

    def test_start_does_not_restart_loaded_sidecar(self):
        result, trace = self.invoke("start")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn(" bootstrap ", trace)
        self.assertNotIn("kickstart -k", trace)

    def test_stop_includes_sidecar_but_leaves_independent_proxy_alone(self):
        result, trace = self.invoke("stop")
        self.assertEqual(result.returncode, 0, result.stderr)
        stops = [line for line in trace.splitlines() if " bootout " in line]
        self.assertEqual(len(stops), 3)
        self.assertTrue(stops[0].endswith("com.mrack.sub2api.frontend"))
        self.assertTrue(stops[-1].endswith("com.mrack.sub2api.mihomo-codex"))
        self.assertNotIn("com.mrack.sub2api.clash", trace)

    def test_stop_reports_failure_without_skipping_other_services(self):
        result, trace = self.invoke("stop", MOCK_BOOTOUT_FAILURE="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(trace.count("launchctl bootout "), 3)

    def test_sidecar_failure_keeps_core_starting_but_returns_failure(self):
        (self.agents / "com.mrack.sub2api.mihomo-codex.plist").unlink()
        result, trace = self.invoke("start", MOCK_NOT_LOADED="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("com.mrack.sub2api.mihomo-codex.plist", result.stderr)
        self.assertIn("com.mrack.sub2api.backend.plist", trace)
        self.assertIn("com.mrack.sub2api.frontend.plist", trace)

    def test_offline_sidecar_is_reported_without_force_restart(self):
        result, trace = self.invoke("start", MOCK_OFFLINE_PORT="3101")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("3101", result.stderr)
        self.assertNotIn("kickstart -k", trace)

    def test_legacy_services_require_explicit_opt_in(self):
        for name in ("mock", "clash"):
            (self.agents / f"com.mrack.sub2api.{name}.plist").touch()
        result, trace = self.invoke("start", SUB2_ENABLE_LEGACY_SERVICES="1", MOCK_NOT_LOADED="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(trace.count("launchctl bootstrap "), 5)