"""Exercise deployment shell behavior without Docker, credentials or live services."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent


class RuntimeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.env = {
            **os.environ,
            "PATH": f"{self.bin}:/usr/bin:/bin",
            "DNS_CLUSTER_QUERY": "tasks.test-api",
            "TIKKIT_CLUSTER_IP_PREFIX": "10.0.2.",
            "LOCAL_IPS": "10.0.1.9 10.0.2.9",
            "DNS_IPS": "10.0.2.8 STREAM\n10.0.2.9 STREAM\n10.0.2.9 DGRAM",
        }
        self.stub("hostname", 'printf "%s\\n" "$LOCAL_IPS"')
        self.stub("getent", 'printf "%s\\n" "$DNS_IPS"')
        self.stub("sleep", "exit 0")
        self.stub("server", 'printf "%s\\n" "$RELEASE_NODE"')
        self.stub("curl", 'exit "${HTTP_STATUS:-0}"')
        self.stub("tikkit", f'echo "$RELEASE_NODE" >> "{self.root}/rpc-calls"; exit "${{RPC_STATUS:-0}}"')
        for name in ["start.sh", "healthcheck.sh"]:
            source = (ROOT / name).read_text()
            source = source.replace("/tmp/tikkit-", f"{self.root}/tikkit-")
            source = source.replace("/app/bin/server", str(self.bin / "server"))
            source = source.replace("/app/bin/tikkit", str(self.bin / "tikkit"))
            (self.root / name).write_text(source)
        (self.root / "tikkit-release-node").write_text("tikkit@10.0.2.9\n")

    def stub(self, name, body):
        path = self.bin / name
        path.write_text(f"#!/bin/sh\n{body}\n")
        path.chmod(0o755)

    def run_script(self, name):
        return subprocess.run(
            ["/bin/sh", str(self.root / name)], env=self.env,
            capture_output=True, text=True, timeout=10, check=False,
        )

    def test_start_selects_cluster_subnet_instead_of_first_interface(self):
        result = self.run_script("start.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "tikkit@10.0.2.9")

    def test_start_clears_previous_readiness_marker(self):
        marker = self.root / "tikkit-cluster-ready"
        marker.touch()
        self.assertEqual(self.run_script("start.sh").returncode, 0)
        self.assertFalse(marker.exists())

    def test_start_refuses_missing_cluster_interface(self):
        self.env["LOCAL_IPS"] = "10.0.1.9"
        result = self.run_script("start.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("No local task IP", result.stderr)

    def test_start_requires_cluster_prefix(self):
        del self.env["TIKKIT_CLUSTER_IP_PREFIX"]
        self.assertNotEqual(self.run_script("start.sh").returncode, 0)

    def test_start_does_not_wait_for_its_unpublished_dns_record(self):
        self.stub("getent", "exit 2")
        self.assertEqual(self.run_script("start.sh").returncode, 0)

    def test_start_refuses_ambiguous_cluster_addresses(self):
        self.env["LOCAL_IPS"] = "10.0.2.9 10.0.2.10"
        self.assertNotEqual(self.run_script("start.sh").returncode, 0)

    def test_unhealthy_http_never_marks_ready(self):
        self.env["HTTP_STATUS"] = "22"
        self.assertNotEqual(self.run_script("healthcheck.sh").returncode, 0)
        self.assertFalse((self.root / "tikkit-cluster-ready").exists())
        self.assertFalse((self.root / "rpc-calls").exists())

    def test_failed_cluster_check_never_marks_ready(self):
        self.env["RPC_STATUS"] = "1"
        self.assertNotEqual(self.run_script("healthcheck.sh").returncode, 0)
        self.assertFalse((self.root / "tikkit-cluster-ready").exists())

    def test_cluster_is_gated_once_but_database_health_is_always_checked(self):
        self.assertEqual(self.run_script("healthcheck.sh").returncode, 0)
        self.env["RPC_STATUS"] = "1"
        self.assertEqual(self.run_script("healthcheck.sh").returncode, 0)
        self.assertEqual((self.root / "rpc-calls").read_text().splitlines(), ["tikkit@10.0.2.9"])
        self.env["HTTP_STATUS"] = "22"
        self.assertNotEqual(self.run_script("healthcheck.sh").returncode, 0)


if __name__ == "__main__":
    unittest.main()
