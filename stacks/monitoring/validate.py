"""Read-only configuration checks using the pinned images and Python stdlib.

Run: python3 stacks/monitoring/validate.py
Requires Docker and the pinned images already present locally. Does not deploy,
publish ports, attach to observability, or mount persistent data volumes.
"""

import json
import os
from pathlib import Path
import re
import subprocess
from urllib.parse import unquote

ROOT = Path(__file__).resolve().parent


def check(command, *, env=None):
    result = subprocess.run(
        command, cwd=ROOT, env=env, capture_output=True, text=True, timeout=90,
        check=False,
    )
    if result.returncode:
        raise SystemExit(result.stdout + result.stderr)


def walk_json(value):
    yield value
    if isinstance(value, dict):
        children = value.values()
    elif isinstance(value, list):
        children = value
    else:
        return
    for child in children:
        yield from walk_json(child)


def variables(dashboard):
    return {item["name"] for item in dashboard.get("templating", {}).get("list", [])}


def validate_layout(panels, path):
    rectangles = []
    for panel in panels:
        if "gridPos" not in panel:
            continue
        pos = panel["gridPos"]
        x, y, w, h = (pos[key] for key in ("x", "y", "w", "h"))
        if not (0 <= x < x + w <= 24 and 0 <= y < y + h):
            raise SystemExit(f"Invalid panel bounds: {path}, panel {panel['id']}")
        for px, py, pw, ph in rectangles:
            if x < px + pw and px < x + w and y < py + ph and py < y + h:
                raise SystemExit(f"Overlapping panels: {path}, panel {panel['id']}")
        rectangles.append((x, y, w, h))


def validate_link(url, path, dashboards):
    match = re.match(r"/d/([^/?]+)", url)
    if not match or "$" in match[1]:
        return
    uid = match[1]
    if uid not in dashboards:
        raise SystemExit(f"Unknown dashboard link {uid}: {path}")
    passed = set(re.findall(r"\$\{(\w+):queryparam\}", url))
    passed.update(re.findall(r"[?&]var-([\w-]+)=", url))
    unsupported = passed - variables(dashboards[uid])
    if unsupported:
        raise SystemExit(f"Unsupported destination selectors {sorted(unsupported)}: {path}")


def validate_dashboard_contract(dashboard, path, dashboards):
    nodes = list(walk_json(dashboard))
    groups = [node["panels"] for node in nodes if isinstance(node, dict) and "panels" in node]
    panel_ids = [panel["id"] for group in groups for panel in group]
    if len(panel_ids) != len(set(panel_ids)):
        raise SystemExit(f"Duplicate panel IDs: {path}")
    for group in groups:
        validate_layout(group, path)
    defined = variables(dashboard)
    for node in nodes:
        if isinstance(node, str):
            # Explore stores its query model in a percent-encoded URL.
            names = re.findall(r"\$\{([A-Za-z_]\w*)[^}]*\}|\$([A-Za-z_]\w*)", unquote(node))
            undefined = {a or b for a, b in names if not (a or b).startswith("__")} - defined
            if undefined:
                raise SystemExit(f"Undefined variables {sorted(undefined)}: {path}")
        elif isinstance(node, dict) and "url" in node:
            validate_link(unquote(node["url"]), path, dashboards)


def validate_dashboards():
    dashboards = {}
    paths = {}
    for path in sorted((ROOT / "grafana/dashboards").rglob("*.json")):
        dashboard = json.loads(path.read_text())
        uid = dashboard["uid"]
        if not uid or uid in dashboards:
            raise SystemExit(f"Duplicate or missing dashboard UID: {path}")
        dashboards[uid] = dashboard
        paths[uid] = path
    for uid, dashboard in dashboards.items():
        validate_dashboard_contract(dashboard, paths[uid], dashboards)
        print(f"OK dashboard JSON/IDs/layout/links/variables: {paths[uid].relative_to(ROOT)}")


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
