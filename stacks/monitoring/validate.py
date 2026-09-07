"""Read-only configuration checks using the pinned images and Python stdlib.

Run: python3 stacks/monitoring/validate.py
Requires Docker and the pinned images already present locally. Does not deploy,
publish ports, attach to observability, or mount persistent data volumes.
"""

import json
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parent


def check(command, *, env=None):
    result = subprocess.run(
        command, cwd=ROOT, env=env, capture_output=True, text=True, timeout=90,
        check=False,
    )
    if result.returncode:
        raise SystemExit(result.stdout + result.stderr)


def validate_dashboards():
    uids = set()
    for path in sorted((ROOT / "grafana/dashboards").rglob("*.json")):
        dashboard = json.loads(path.read_text())
        uid = dashboard["uid"]
        if not uid or uid in uids:
            raise SystemExit(f"Duplicate or missing dashboard UID: {path}")
        uids.add(uid)
        panel_ids = [panel["id"] for panel in dashboard["panels"]]
        if len(panel_ids) != len(set(panel_ids)):
            raise SystemExit(f"Duplicate panel IDs: {path}")
        print(f"OK dashboard JSON/IDs: {path.relative_to(ROOT)}")


def validate_component(images, name, binary, config, arguments):
    # Mount only configuration, never a running service's data directory.
    target = "/tmp/validate-config"
    check([
        "docker", "run", "--rm", "--pull=never", "--network=none",
        "--read-only", "--entrypoint", binary,
        "--mount", f"type=bind,source={ROOT / config},target={target},readonly",
        images[name], *[arg.replace("{config}", target) for arg in arguments],
    ])
    print(f"OK pinned-image validation: {config}")


def main():
    # This tracked file contains only public immutable image references.
    images = dict(
        line.split("=", 1) for line in (ROOT / "dokploy.env").read_text().splitlines()
        if line and not line.startswith("#")
    )
    env = {**os.environ, **images, "GRAFANA_HOST": "grafana.example.invalid"}
    check(["docker", "stack", "config", "--compose-file", "docker-stack.yml"], env=env)
    print("OK Swarm manifest interpolation")
    validate_dashboards()
    validate_component(images, "ALLOY_IMAGE", "/bin/alloy", "alloy/config.alloy",
                       ["validate", "{config}"])
    validate_component(images, "TEMPO_IMAGE", "/tempo", "tempo/tempo.yml",
                       ["-config.file={config}", "-config.verify=true"])
    validate_component(images, "PROMETHEUS_IMAGE", "/bin/promtool", "prometheus/prometheus.yml",
                       ["check", "config", "{config}"])
    print("Grafana provisioning and live queries must also be checked after deployment; see README.")


if __name__ == "__main__":
    main()
