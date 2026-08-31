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
  prometheus/prometheus.yml
  loki/loki.yml
  tempo/tempo.yml
  grafana/provisioning/                      # datasources and dashboard loader
  grafana/dashboards/                        # version-controlled dashboard JSON
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
repository. The dashboard JSON is mounted directly into Grafana's existing
`/etc/grafana/provisioning/dashboards` directory, outside its persistent data
volume.

No active alert rules or contact points are provisioned. Add a contact point
before adding alert rules; Grafana otherwise attempts its default SMTP notifier.

## Telemetry producer contract

This stack accepts standard OpenTelemetry Protocol telemetry from any compatible
Dokploy Application service attached to `observability`.

- Send traces and metrics to `http://alloy:4318` using OTLP/HTTP, or gRPC to
  `alloy:4317`.
- Configure batching, finite timeouts, and retry limits so telemetry failures
  never affect application requests.
- Write structured JSON logs to container stdout. Alloy collects Swarm task
  logs through the Docker socket; include a lowercase 32-character `trace_id`
  field when available for Loki-to-Tempo links.
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
