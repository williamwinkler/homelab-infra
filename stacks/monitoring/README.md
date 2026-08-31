# Monitoring stack

A lightweight single-server LGTM stack for Dokploy using **Docker Compose**, not
Docker Swarm:

```text
Dokploy Compose applications (same Docker host)
  └─ OTLP HTTP :4318 / gRPC :4317 over `observability` bridge
       └─ Alloy
            ├─ traces  ──OTLP──> Tempo
            ├─ metrics ─remote-write──> Prometheus
            └─ logs    ──Loki push──> Loki

Grafana ──queries──> Prometheus + Loki + Tempo
```

Grafana and Prometheus are served by Dokploy/Traefik as **plain HTTP on
Tailscale-only hostnames**. They need no public DNS record, Let's Encrypt
certificate, or HTTPS. The server firewall must allow Traefik TCP/80 only over
Tailscale and deny it on the public interface. Tailscale encrypts the client to
server path.

## Repository layout

```text
ansible/
  playbooks/configure_homelab_hosts.yml  # install private aliases on a Mac
  vars/homelab.yml                       # Dokploy MagicDNS name and Tailscale IP
terraform/dokploy/
  monitoring.tf                          # Dokploy project/environment/Compose/routes
  monitoring.tfvars.example              # one `monitoring` input object
stacks/monitoring/
  docker-compose.yml                     # single-host service definition
  dokploy.env                            # non-secret, version-pinned image refs
  alloy/config.alloy                     # OTLP gateway + Docker stdout collection
  prometheus/prometheus.yml
  loki/loki.yml
  tempo/tempo.yml
  grafana/provisioning/                  # data sources, dashboard loader, alert rule
  grafana/dashboards/                    # version-controlled dashboard JSON
```

## Ownership

| Concern | Owner | Why |
| --- | --- | --- |
| Ubuntu packages, Docker, Tailscale, firewall, Dokploy | Ansible bootstrap playbook/roles | Host state must exist before Dokploy can deploy. |
| `observability` bridge | Monitoring Compose project | Docker Compose creates the named bridge during the initial Dokploy deployment. |
| Dokploy `Monitoring` project, environment, Compose source, HTTP routes | Terraform | The Dokploy provider has native project, environment, Compose, and domain resources. |
| Services, health checks, volumes, service names, bind mounts | `docker-compose.yml` | Dokploy deploys this Git-backed file with Docker Compose. |
| Data sources, dashboards, alert rules | Grafana file provisioning | Deterministic and version-controlled. |

### Terraform boundary

The configured `ahmedali6/dokploy` provider is community-maintained and uses
Dokploy's API. It manages projects, environments, Compose applications and
Traefik domains. It has no standalone Docker-network resource; instead, the
Monitoring Compose deployment creates its named bridge during first deployment.

Terraform uses `compose_type = "docker-compose"`. The Compose file is cloned
from this repository so its relative configuration bind mounts are available on
the Dokploy host. Do not put Grafana passwords, SMTP credentials, or API keys
in `dokploy.env`, `*.tfvars`, or Terraform's Compose `env` string: Terraform
state retains those values.

## Networking

Dokploy Compose projects create isolated networks by default. To let future
applications send OTLP data to Alloy without public traffic, the Monitoring
Compose project creates one named Docker **bridge** network, `observability`,
on its first deployment:

```text
Docker host only
  Application Compose service ── observability bridge ── Alloy
```

1. The Monitoring Compose project owns and attaches every service to
   `observability`.
2. Every telemetry-producing application must also be a Dokploy **Compose**
   project and attach to the already-created bridge as an external network.
3. Applications use `http://alloy:4318` or `alloy:4317`; `alloy` is a Docker
   network alias, not a host address.
4. Do not publish ports 4317, 4318, 9090, 3100, 3200 or 12345 to the host.

The native Dokploy Application resource's Swarm network settings do not apply
to this Compose-only design. Use Compose for applications that require the
shared telemetry network.

## Private UIs

| Service | Private hostname | Dokploy target | Access |
| --- | --- | --- | --- |
| Grafana | `grafana.home.arpa` | `grafana:3000` | Tailscale-only HTTP |
| Prometheus | `prometheus.home.arpa` | `prometheus:9090` | Tailscale-only HTTP |

On each managed Mac, the local Ansible playbook writes these names to
`/etc/hosts`, resolving them to the Dokploy server's Tailscale address. The
browser sends the hostname to Traefik, which chooses the Grafana or Prometheus
service. This is routing—not a direct port mapping.

Prometheus has no built-in authentication in this deployment, so do not make
its route public. Grafana starts with its upstream default initial credential
(`admin` / `admin`), sign-up disabled, and no anonymous access. Change that
password at first sign-in; Tailscale is a network boundary, not a substitute for
a non-default password.

## Persistence and retention

| Component | Volume | Default | Rationale |
| --- | --- | --- | --- |
| Grafana | `grafana-data` | retained indefinitely | Users, alert state, local SQLite state. |
| Prometheus | `prometheus-data` | 15 days or 12 GB | Bounds metrics disk use. |
| Loki | `loki-data` | 7 days | Logs normally dominate disk use. |
| Tempo | `tempo-data` | 7 days | Keeps local trace blocks small. |
| Alloy | `alloy-data` | retained | Collector local state. |

This is deliberately a one-host, non-HA design. Named volumes are local to the
Dokploy server. Back up `grafana-data` daily and snapshot or briefly stop the
relevant service before copying live Prometheus, Loki, or Tempo data. Keep an
encrypted off-host backup and test restoration.

## Grafana configuration

Use Grafana provisioning files for data sources and dashboards. In Compose they
are read-only bind mounts from this repository. Use the Grafana UI to develop or
debug a dashboard, export its JSON, remove its numeric `id`, commit it, then
redeploy. Do not manually maintain production dashboards in the UI. Configure
an alert contact point before adding alert rules; Grafana otherwise attempts its
default SMTP notifier, which is intentionally not configured in this stack.

Grafana Terraform is optional later for API-only resources such as service
accounts, teams, or RBAC. It requires Grafana to exist first plus an API token
and Terraform state, so it is not the default for this single instance.

### Scope

Grafana's included platform overview is limited to the monitoring stack's own
health and ingestion signals. Dokploy's UI is the source of truth for host,
container, and proxy traffic metrics in this single-server setup. This stack
does not run node_exporter, cAdvisor, or scrape Dokploy/Traefik metrics.

## Telemetry producer contract

This stack accepts standard OpenTelemetry Protocol telemetry from any compatible
application. Attach a producer's Compose service to `observability` and use
`http://alloy:4318` for OTLP/HTTP or `alloy:4317` for OTLP/gRPC. Configure
batching, finite timeouts, and retry limits so telemetry failures never affect
application requests.

For logs, structured JSON written to container stdout is the portable fallback;
Alloy collects it from Docker. The OTLP log route is available for producers
that support it.

## Fresh-server procedure

> Run these commands yourself; this repository does not apply Ansible or
> Terraform automatically.

1. Bootstrap Ubuntu with Docker, Tailscale, a firewall that admits Traefik
   HTTP only through Tailscale, and Dokploy. No Docker Swarm initialization is
   required for this monitoring deployment.
2. Review the immutable image digests in `dokploy.env` and commit any deliberate
   image upgrade only after resolving and testing its new digest. Never use
   `latest`.
3. On each laptop, copy `terraform/dokploy/.env.example` to `.env`, put the
   Dokploy API key in that ignored file, then source it as documented in
   `terraform/README.md`. The committed `common.tfvars` contains the shared,
   non-secret monitoring configuration and `terraform.tfstate` preserves the
   existing resource IDs.
4. From `terraform/dokploy/`, run `terraform init`, review
   `terraform plan -var-file=common.tfvars`, and apply Terraform. Dokploy clones
   this repository, creates `observability`, and deploys
   `stacks/monitoring/docker-compose.yml`.
5. On each Mac, run
   `ansible-playbook playbooks/configure_homelab_hosts.yml --ask-become-pass`
   from `ansible/`, then browse `http://grafana.home.arpa` and
   `http://prometheus.home.arpa` over Tailscale. Change Grafana's default
   `admin` password immediately.
6. Deploy telemetry-producing applications as Compose projects attached to
   `observability`, configure their OTLP endpoints, and verify traces, metrics,
   and JSON logs.

## Operations

- **Authentication:** Tailscale is the network perimeter. Change Grafana's
  initial `admin` / `admin` password immediately; Prometheus remains
  Tailscale-only. Add Grafana OIDC if multiple users need access.
- **TLS:** this design intentionally uses HTTP over the encrypted Tailscale
  path. Revisit TLS and OTLP authentication before exposing any route publicly.
- **Health checks:** the LGTM backends have local HTTP health checks.
  Dokploy/Traefik routes only the two private UI services; all backends remain
  unexposed.
- **Upgrades:** update one digest at a time, deploy, verify health and data
  sources, then continue. Compose recreates containers; brief telemetry gaps
  are expected during Alloy upgrades.
- **Failure behavior:** Alloy batches and retries briefly. A full queue or a
  backend outage drops telemetry rather than blocking application requests.
  Telemetry must never make an application unavailable.

## Trade-offs

- Docker Compose is simpler than Swarm for one permanent host: no overlay,
  node labels, Swarm configs, secrets, or deployment policies.
- Compose does not provide rolling upgrades or multi-node recovery. This is
  acceptable for a homelab where short monitoring interruption is preferable to
  additional operational complexity.
- Applications that need OTLP must be Compose projects so they can join the
  shared bridge. This is a deliberate constraint of the simple design.
- The default Grafana password is intentionally simple but weak. Change it at
  first login; move to a Dokploy external secret provider if stronger,
  repeatable secret management is later needed.

## Primary references

- [Dokploy Docker Compose](https://docs.dokploy.com/docs/core/docker-compose)
- [Dokploy API](https://docs.dokploy.com/docs/api)
- [Dokploy Terraform Compose resource](https://github.com/AhmedAli6/terraform-provider-dokploy/blob/main/docs/resources/compose.md)
- [Alloy OTLP receiver](https://grafana.com/docs/alloy/latest/reference/components/otelcol/otelcol.receiver.otlp/)
- [Grafana provisioning](https://grafana.com/docs/grafana/latest/administration/provisioning/)
- [Dokploy monitoring](https://docs.dokploy.com/docs/core/monitoring)
