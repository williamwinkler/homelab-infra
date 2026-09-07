# Monitoring stack

A single-server LGTM stack for Dokploy using a **Docker Swarm stack**:

```text
Dokploy Application services (Swarm)
  └─ OTLP HTTP :4318 / gRPC :4317 over `observability` overlay
       └─ Alloy
            ├─ traces  ──OTLP──> Tempo
            ├─ metrics ─remote-write──> Prometheus
            └─ logs    ──Loki push──> Loki

Grafana ──queries──> Prometheus + Loki + Tempo
```

Grafana and Prometheus are served by Dokploy/Traefik as **plain HTTP on
Tailscale-only hostnames**. They need no public DNS record, certificate, or
HTTPS. The server firewall must allow Traefik TCP/80 only over Tailscale and
deny it on the public interface.

## Repository layout

```text
ansible/
  playbooks/create_observability_network.yml # attachable Swarm overlay
  playbooks/configure_homelab_hosts.yml      # private aliases on a Mac
  vars/homelab.yml                           # Dokploy MagicDNS name and Tailnet IP
terraform/dokploy/
  monitoring.tf                              # Dokploy project, Stack, and routes
  monitoring.tfvars.example                  # monitoring input object example
stacks/monitoring/
  docker-stack.yml                           # single-host Swarm service definition
  dokploy.env                                # non-secret immutable image refs
  alloy/config.alloy                         # OTLP gateway + Docker stdout collector
  blackbox/blackbox.yml                      # HTTP probe module definitions
  prometheus/prometheus.yml
  loki/loki.yml
  tempo/tempo.yml
  grafana/provisioning/                      # datasources and dashboard loader
  grafana/dashboards/                        # Platform + opt-in application dashboards
  validate.py                                # read-only pinned-image configuration checks
```

## Ownership

| Concern | Owner | Why |
| --- | --- | --- |
| Ubuntu packages, Docker, Tailscale, firewall, Dokploy | Ansible bootstrap | Host state must exist before Dokploy deploys. |
| `observability` overlay | Ansible prerequisite | Dokploy has no Docker-network resource; the overlay must be attachable by Swarm Applications. |
| Monitoring project, Stack source, HTTP routes | Terraform | The Dokploy provider manages these API resources. |
| Services, volumes, health checks, bind mounts | `docker-stack.yml` | Dokploy deploys this Git-backed Swarm manifest. |
| Datasources and dashboards | Grafana file provisioning | Deterministic and version-controlled. |

## Networking

`observability` is an **external attachable overlay network**, created once by
Ansible. Both the Monitoring Stack and Dokploy Application services attach to
it. Alloy is available through Docker DNS as `alloy`:

```text
Swarm Application service ── observability overlay ── Alloy
```

1. Run `create_observability_network.yml` before the first Stack deployment.
2. Set an Application's Dokploy **Network Target** to `observability`.
3. Applications use `http://alloy:4318` or `alloy:4317`; neither is a host
   address.
4. Do not publish ports 4317, 4318, 9090, 3100, 3200, or 12345 to the host.

The overlay is a Swarm prerequisite. The playbook fails safely if the retired
Compose bridge still owns the `observability` name.

## Private UIs

| Service | Private hostname | Dokploy target | Access |
| --- | --- | --- | --- |
| Grafana | `grafana.home.arpa` | `grafana:3000` | Tailscale-only HTTP |
| Prometheus | `prometheus.home.arpa` | `prometheus:9090` | Tailscale-only HTTP |

On each managed Mac, the local Ansible playbook writes these names to
`/etc/hosts`, resolving them to the Dokploy server's Tailscale address.

Prometheus has no built-in authentication in this deployment, so do not make
its route public. Grafana starts with its upstream initial credential
(`admin` / `admin`), sign-up disabled, and no anonymous access. Change that
password at first sign-in.

## Persistence and placement

Each service has one replica constrained to the Swarm manager. Grafana,
Prometheus, Loki, Tempo, and Alloy store data in local named volumes on that
host. This is intentionally single-node, non-HA monitoring: do not increase
replicas or add Swarm nodes without changing storage design.

| Component | Default retention |
| --- | --- |
| Grafana | retained indefinitely |
| Prometheus | 15 days or 12 GB |
| Loki | 7 days |
| Tempo | 7 days |
| Alloy | retained local state |

Back up Grafana daily and snapshot or briefly stop the relevant service before
copying live Prometheus, Loki, or Tempo data.

## Grafana configuration

Datasources and dashboards are read-only provisioning bind mounts from this
repository, outside Grafana's persistent data volume. The existing overview
lives in **Platform**. Application dashboards use the separate **Applications**
folder and `/etc/grafana/dashboards/applications` provider path. Mount individual
JSON files, not the data volume or a directory that hides existing provisioning.

The shared stack and data sources remain application-agnostic. Project-specific
metrics and queries belong in application dashboards, not collector filters or
shared trace-to-metrics links. **Applications → Tikkit API** is the first such
dashboard (`/d/tikkit-api`): RPC outcomes/latency, database timing, BEAM health,
related logs and RPC traces. Its environment/action filters and Explore links
preserve investigation context. Database/VM/log panels are service-scoped, not
RPC-action-scoped; an aggregate graph cannot identify every individual request.

No active alert rules or contact points are provisioned. Add a contact point
before adding alert rules; Grafana otherwise attempts its default SMTP notifier.
Choose actionable sustained error/latency conditions and link alerts to the
relevant dashboard. Expected validation/rate-limit responses should not
indiscriminately page as internal service failures.

### Cross-signal navigation

| From → to | Provisioned behavior |
| --- | --- |
| Logs → trace | Extract `trace_id`, `traceid`, or LoggerJSON's `trace` and open Tempo. |
| Trace → logs | Match `service.name` to Loki `service_name`, then filter the exact trace ID within ±5 minutes. |
| Trace → metrics | Match service/environment and open generic server rate, error rate, and p95 latency queries. |
| Metric → trace | Grafana recognizes both Alloy's `trace_id` and Tempo's `traceID` exemplars. |
| Dashboard → logs/traces | Application-specific Explore links retain the selected time range and identity. |
| Service dependencies | Tempo generates service-graph metrics; its Grafana data source points to Prometheus. |

Tempo's `service-graphs` and `span-metrics` processors are explicitly enabled.
Their metrics reflect **received/sampled spans**, not necessarily all requests.
They complement rather than replace application counters used for SLOs. Service
maps require suitable client/server/database spans; configuration cannot invent
missing instrumentation. Existing stored traces are not retroactively turned
into generator metrics.

Prometheus exemplar storage is enabled (default bounded 100,000-exemplar ring),
and Alloy/Tempo forward exemplars. A producer must still emit them with trace
context. A graph point links to an **example** request, not every request in its
aggregate. Sampling, trace retention, and exemplar-ring eviction can make a link
unavailable. No trace IDs or request/user IDs are added as metric labels.

## Availability probes

Prometheus invokes the private Blackbox Exporter with its `http_2xx` module
once every 30 seconds to probe these public HTTPS endpoints:

- `https://hscards.william-winkler.com`
- `https://william-winkler.com`

The `blackbox_https` job exposes `probe_success` (`1` is online, `0` is a
failed probe), response timing, DNS, TLS, and HTTP-status metrics. The
exporter is only reachable on the `observability` overlay; do not publish its
port 9115.

## Telemetry producer contract

This stack accepts standard OpenTelemetry Protocol telemetry from any compatible
Dokploy Application service attached to `observability`.

- Send traces and metrics to `http://alloy:4318` using OTLP/HTTP, or gRPC to
  `alloy:4317`. Give each resource a stable `service.name`, optional
  `service.namespace`/`service.version`, and an explicit deployment environment.
  Prefer `deployment.environment.name` for new producers; Alloy adds the legacy
  `deployment.environment` alias when absent, retaining compatibility with
  existing applications. The common query label is `deployment_environment`.
  Do not infer deployment environment from a production compiler build.
- Configure batching, finite timeouts, and retry limits so telemetry failures
  never affect application requests.
- Write structured JSON logs to container stdout. Alloy collects container and
  Swarm task logs through the Docker socket. Include lowercase `trace_id`
  (32 hex characters) and `span_id` (16) when available. LoggerJSON's `trace`
  and `span` fields are supported too.
- Include `service_name`, `service_namespace`, `deployment_environment`, and
  `service_version` at JSON top level or inside `metadata`, using the same
  identity as the OTel resource. Alloy promotes only service, namespace, and
  environment to labels; version and trace/span IDs remain structured metadata.
  Docker service/container names are fallbacks, not substitutes for explicit
  resource identity (Dokploy service names may differ from `service.name`).
- Producers using OTLP logs instead of stdout receive the same bounded identity
  labels through the Loki exporter's resource-label hint, unless they explicitly
  override that hint. This does not require application-specific collector code.
- Existing logs are not relabeled retroactively. Trace-to-log links deliberately
  use service + exact trace ID, without requiring an environment label, so older
  logs remain reachable. Filtering a dashboard to a specific environment only
  includes logs that actually carry that label.
- Avoid simultaneous Docker-stdout and OTLP log export unless duplicate logs
  are intentional.

## Clean migration from the retired Compose deployment

This migration intentionally discards existing monitoring data.

1. The Dokploy provider cannot change `compose_type` from `docker-compose` to
   `stack` in place. Destroy only the disposable Compose resource and its two
   routes through Terraform; retain the Monitoring project and environment:

   ```zsh
   cd terraform/dokploy
   terraform destroy -var-file=common.tfvars \
     -target=dokploy_domain.grafana \
     -target=dokploy_domain.prometheus \
     -target=dokploy_compose.monitoring
   ```

2. On the Dokploy host, remove the retired `observability` bridge and its old
   monitoring volumes after confirming nothing depends on them.
3. Run the overlay prerequisite:

   ```zsh
   cd ansible
   ansible-playbook playbooks/create_observability_network.yml \
     -i inventory --ask-become-pass
   ```

4. Commit and push this Stack manifest, then run a normal Terraform plan and
   apply. Terraform creates a new `stack` Compose resource and recreates the
   Grafana and Prometheus routes under the existing Monitoring project and
   environment.
5. Verify Grafana and Prometheus routes, Grafana datasources, and Alloy
   readiness before attaching Application services.

> Run these commands yourself; this repository does not apply Ansible or
> Terraform automatically.

## Validation and local development

Before deployment, from the repository root:

```sh
python3 stacks/monitoring/validate.py
```

This uses Python's standard library and the pinned images already cached in
Docker. It checks manifest interpolation, dashboard JSON/IDs, Alloy, Tempo,
and Prometheus configuration. Validation containers have no network, published
ports, or persistent data volumes. It does not apply Terraform/Ansible or deploy
services. Grafana provisioning is additionally validated by Grafana at startup.

After deployment, verify:

1. All six services are healthy and Grafana's three data sources pass health checks.
2. The Applications dashboard loads; run its PromQL, LogQL, and TraceQL queries.
   Sparse traffic produces gaps/NaN latency, not evidence of a broken pipeline.
3. Generate fresh requests; locate their logs and follow the trace link back.
4. From a trace, check related logs and generic metrics. Span metrics only start
   accumulating after the processors are enabled.
5. Query Prometheus `/api/v1/query_exemplars` for a histogram and resolve one of
   its trace IDs in Tempo. Both transport and retained trace existence matter.
6. Confirm Grafana's service map once client/dependency spans have arrived.

The local Docker Desktop Swarm may have manual overrides (Grafana on port 3000,
Docker Desktop's socket mount). Preserve those when applying targeted local
service updates; do not copy them into the private Dokploy production manifest.
Confirm `docker context show` and service bind-mount sources before updating.
A Prometheus flag change and Tempo processor activation require their services
to restart; Alloy supports its reload endpoint. Provisioning can be reloaded via
Grafana's admin API, while a new dashboard bind mount requires a Grafana service
update. Never remove the stack or its volumes to apply these changes.

## Operations

- **Authentication:** Change Grafana's initial `admin` / `admin` password
  immediately. Prometheus remains Tailscale-only.
- **Stack updates:** Update one image digest at a time, deploy, and verify
  health and datasources before continuing.
- **Failure behavior:** Alloy batches and retries briefly. A full queue or
  backend outage drops telemetry rather than blocking application requests.
- **Application rolling updates:** Configure them in Dokploy Application →
  Advanced → Swarm Settings → Update Config. Monitoring itself remains a
  single-replica stateful Stack.

## Primary references

- [Dokploy Docker Compose / Stack](https://docs.dokploy.com/docs/core/docker-compose)
- [Dokploy Application advanced settings](https://docs.dokploy.com/docs/core/applications/advanced)
- [Dokploy Terraform Compose resource](https://github.com/AhmedAli6/terraform-provider-dokploy/blob/main/docs/resources/compose.md)
- [Alloy OTLP receiver](https://grafana.com/docs/alloy/latest/reference/components/otelcol/otelcol.receiver.otlp/)
- [Grafana provisioning](https://grafana.com/docs/grafana/latest/administration/provisioning/)
