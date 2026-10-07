# Tikkit on Dokploy

Terraform creates the project, production environment, two Docker-image
Applications, runtime file mounts, and four HTTP routes. It does **not** deploy
Tikkit. Images are built and pushed from the Tikkit repo, then you click
**Deploy** in Dokploy for each release; auto-deploy and previews are disabled.

## Releasing

```sh
# In the tikkit repo, once: docker login (Docker Hub user williamwinkler)
scripts/docker-push.sh        # builds linux/amd64, pushes tikkit-api and tikkit-web
scripts/docker-push.sh api    # or only one image
```

Both images are public: `docker.io/williamwinkler/tikkit-api` and
`docker.io/williamwinkler/tikkit-web`. Dokploy 0.30 nevertheless requires registry
credentials for Docker-image apps, so Terraform passes the Docker Hub username
and a token with **Public Repo Read-only** scope (`TF_VAR_tikkit_registry_token`
in `.env`). That token ends up in the committed state; its scope makes it
useless beyond what anonymous pulls already allow. Never use a write token here. Each push updates `:latest` and also
writes the short commit SHA tag. Dokploy runs `docker pull` of `:latest` on every
**Deploy** and then force-updates the Swarm service, so a Deploy always picks up
the most recently pushed image. Deploy the API first when a release changes both.

## Architecture

```text
Browser HTTPS/WSS → Cloudflare Tunnel → Dokploy Traefik HTTP :80
  Host: tikkit.life
    /api, /socket, /mcp → Phoenix :4000 → existing PostgreSQL
    /            → Nginx :80 → static SPA

API → observability overlay → Alloy :4318 → Tempo / Prometheus
API + web stdout → Alloy Docker discovery → Loki
API + web container labels → Alloy cAdvisor → Prometheus
```

The web Dockerfile builds with Bun but its runtime is only Nginx. Dokploy's
ordinary **Application** deployment itself uses Swarm; the web app simply uses
one replica and stop-first updates. No Node/Bun server or Compose stack is needed.
The API also uses an Application, with one replica and start-first updates.

The web image is built from the repo root with `apps/web/Dockerfile`; the API
image from `apps/api` with `apps/api/Dockerfile`. Dokploy builds nothing.
This deployment adds no build arguments or public frontend environment variables.

## First-time setup

1. Review `../common.tfvars`. The hostname is **tikkit.life**. This configuration
   targets the existing single Dokploy manager, where Alloy collects Docker logs
   and container metrics. It is not a multi-host storage configuration.
2. Inspect `dokploy-network` and `observability` on the server with
   `docker network inspect dokploy-network observability`. Both must be Swarm
   overlays. The latter already belongs to the monitoring deployment. If it is
   missing, use `ansible/playbooks/create_observability_network.yml` as described
   in the monitoring runbook. Terraform's `network_swarm` attaches existing
   networks; it does **not** create them. Create Tikkit's dedicated cluster overlay
   once using the included Ansible playbook:

   ```sh
   cd ansible
   ansible-playbook playbooks/create_tikkit_network.yml -i inventory --ask-become-pass
   ```

   First confirm `10.77.42.0/24` is unused by existing Docker networks and your
   LAN/VPN routes. Change `ansible/vars/tikkit.yml` if needed; Ansible and Terraform
   both read that file. Use an IPv4 `/24`. The playbook refuses an existing
   network with different settings and never deletes/replaces it. The cluster
   overlay is service-only and has no host-published ports. Changing its subnet
   later requires a deliberate network migration, not an ordinary app rollout.
3. Confirm the existing PostgreSQL endpoint is reachable by containers. A Dokploy
   database normally uses its internal service hostname on `dokploy-network`.
   For a database on another overlay, list that existing network in
   `tikkit.database_networks`. Do not use `localhost` in `DATABASE_URL` and do not
   publish PostgreSQL/EPMD/distribution/OTLP ports. Use a dedicated database with
   permission to run Tikkit's migrations; allow at least two pools of 10 API
   connections plus migration/admin headroom during updates.
4. Prepare Terraform locally:

   ```sh
   cd terraform/dokploy
   cp .env.example .env  # only if .env does not already exist
   # Put the Dokploy API key in .env; do not commit it.
   set -a; . ./.env; set +a
   terraform init
   terraform plan -var-file=common.tfvars
   terraform apply -var-file=common.tfvars
   terraform output tikkit_deployment
   ```

   Review the whole plan, including the existing monitoring resources. Keep the
   repository's pull/apply/commit-state workflow. No Tikkit deployment is triggered
   by creation, domain updates, or image pushes.
5. In **Tikkit → production → environment/shared variables**, save these six
   values, using `KEY=value` syntax without `export`:

   | Variable | Value |
   | --- | --- |
   | `DATABASE_URL` | `ecto://USER:URL_ENCODED_PASSWORD@HOST:5432/DATABASE` for the existing database |
   | `SECRET_KEY_BASE` | Long random secret; preserve between versions |
   | `TOKEN_SIGNING_SECRET` | Separate long random secret; preserve between versions |
   | `RELEASE_COOKIE` | Separate random Erlang cookie, identical for overlapping tasks |
   | `GOOGLE_CLIENT_ID` | Google OAuth client ID |
   | `GOOGLE_CLIENT_SECRET` | Google OAuth client secret |

   Generate each random secret separately with `openssl rand -hex 64` or the
   app's `mix phx.gen.secret`. Configure Google's authorized redirect URI as
   `https://tikkit.life/api/auth/user/google/callback`.

   Terraform sets `PHX_HOST=tikkit.life`, `WEB_URL=https://tikkit.life`, that
   callback URI, port 4000, pool size 10, release distribution, DNS discovery,
   and OTel settings. `/app/bin/server` enables Phoenix and runs migrations.
   `RELEASE_NODE` is generated for each task; never enter a fixed value in the UI.

   **Keep credentials in shared variables.** Application environment fields
   contain `${{environment.NAME}}` references. Provider 0.8.0 reads application
   env into state, but its project/environment resources do not manage shared
   variable contents. Pasting credentials into the app editor would put them in
   this repo's committed state on refresh. `sensitive` or `ignore_changes` would
   not prevent that. Recheck this behavior before upgrading the provider.
6. In the existing Cloudflare Tunnel public hostname for `tikkit.life`, point
   the origin at **Traefik port 80**, retaining `Host: tikkit.life`. For a
   host-installed tunnel that is typically `http://localhost:80`. The existing
   `network-cloudflared` tunnel runs with host networking and already maps
   `tikkit.life` to `http://127.0.0.1:80` (Traefik); nothing to change there. Do not route directly to the web container or Dokploy's
   management port 3000. Keep public HTTPS enabled, enable WebSockets, and bypass
   Cloudflare caching for `/api*` and `/socket*`. No Dokploy certificate or HTTPS
   redirect is needed on this HTTP origin.
7. Check **api → Domains**: `/api`, `/socket` and `/mcp`, port 4000, HTTPS off, **Strip
   Path off**, and no added internal prefix. **web → Domains** has `/`, port 80,
   HTTPS off. The more specific API routes bypass the web image's local-Compose
   proxy to `api:4000`; that local hostname is not used in production.
8. Update the existing monitoring stack from this repo using its manual Deploy
   button so Alloy picks up the generic task-label fallback for Nginx logs.
   Existing API JSON logs/OTLP and cAdvisor already work with the prior collector.
9. Click **Deploy** on **api**, wait for healthy, then **Deploy** on **web**.
   Verify the checks below before treating the deployment as ready.

## Swarm settings and provider support

All required Swarm fields are supported by the already-pinned
`ahmedali6/dokploy` **0.8.0**. No manual Swarm edits are required. Terraform owns
the settings; future applies overwrite manual drift. To inspect or reproduce
them in the UI, open **api → Advanced → Cluster Settings → Swarm Settings**:

| UI setting | Terraform configuration |
| --- | --- |
| Replicas | `1`; no separate Mode override |
| Network | JSON array of `{"Target":"dokploy-network"}`, `{"Target":"observability"}`, `{"Target":"tikkit-cluster","Aliases":["tikkit-api-cluster"]}` and any database overlays |
| Placement | `{"Constraints":["node.role == manager"]}` |
| Update Config | `{"Parallelism":1,"Order":"start-first","FailureAction":"pause","Monitor":180000000000,"MaxFailureRatio":0}` |
| Rollback Config | Same as Update Config; relevant only when deliberately rolling back a service spec |
| Restart Policy | `{"Condition":"any","Delay":5000000000}` |
| Stop Grace Period | `60000000000` (60 seconds) |
| Health Check | `Test: ["CMD","/bin/sh","/app/dokploy/healthcheck.sh"]`, Interval `10000000000`, Timeout `8000000000`, StartPeriod `120000000000`, Retries `3` |
| Labels | `service.name=tikkit-api`, `deployment.environment.name=production` |

Times in these JSON fields are **nanoseconds**. The runtime files under this
directory are Terraform-managed Dokploy file mounts at `/app/dokploy/`.
The command override is `/bin/sh /app/dokploy/start.sh`.
After changing settings, click **Deploy/Redeploy** to apply them to containers.
Do not use **Stop** followed by **Start** for an ordinary API update.

## Clustering and rollout behavior

`DNS_CLUSTER_QUERY=tasks.tikkit-api-cluster` uses an alias assigned **only** on
`tikkit-cluster`. It resolves individual task IPs, not the load-balancer VIP.
`RELEASE_DISTRIBUTION=name` and a shared `RELEASE_COOKIE` enable distributed
Erlang. The startup mount selects its local address on the explicit cluster
subnet and starts `tikkit@<cluster-IP>`.
This matters because the API joins multiple overlays; choosing the first result
of `hostname -i` could select an address that DNSCluster does not advertise.
Swarm publishes task DNS only after health succeeds, so startup must not wait
for its own DNS record. The subnet lets it select an IP before publication.

The healthcheck verifies the existing `/api/health` endpoint (including its
database query). Before its first success it also checks the running node's
identity, connects to already-healthy DNS-discovered peers, and checks Phoenix PubSub membership
in both directions. This check matches Tikkit's current default PG2 adapter and
single PubSub pool partition. Revisit it if that application configuration changes.
An absent DNS record is valid on the very first deployment. Subsequent checks
remain HTTP/database checks, so an old task's departure cannot
make the surviving task unhealthy. The readiness marker is reset on startup.

Swarm starts the replacement before retiring the old healthy task. Neither
`Monitor` nor `StopGracePeriod` reserves a fixed two-container overlap: monitoring
observes failures and grace time is the maximum allowed shutdown time. Health
checks and DNS membership do not prove every possible realtime event is delivered.
WebSockets on the old task eventually close; clients reconnect, resubscribe, and
resync their caches. Phoenix PubSub is transient, with no replay or socket handoff.

The existing release script runs database migrations **before** starting Phoenix.
Use backward-compatible expand/contract migrations, since the old version still
serves traffic against the migrated database. Failed migrations fail startup.
Swarm rollback does not undo migrations. Releases reuse `:latest`,
so rolling back a previous service specification may select the new image again.
For this reason failed updates **pause**, rather than promise automatic image
rollback. For recovery, re-point `:latest` at a known-good SHA tag
(`docker buildx imagetools create -t williamwinkler/tikkit-api:latest
williamwinkler/tikkit-api:<sha>`) and click Deploy. Do not stop a still-healthy old task while diagnosing a
replacement startup failure. Deploying SHA tags instead of `:latest` would make Swarm rollback meaningful.
Every recovery also needs a schema compatible with the old application version.

## Monitoring and verification

The API sends OTLP/HTTP protobuf to `http://alloy:4318`, with
`service.name=tikkit-api`, `service.namespace=tikkit`, and
`deployment.environment.name=production`. Its existing instrumentation supplies
request/database/Ash spans and BEAM/application metrics. JSON logs go to stdout;
Alloy collects them through Docker and correlates trace IDs with Tempo.
There is no second OTLP log exporter to duplicate those logs.

The web image's Nginx access/error logs go to stdout/stderr. Task labels identify
it as `tikkit-web` in Loki and cAdvisor; no overlay connection to Alloy is needed
for Docker collection. It has no server-side JS spans or browser/RUM tracing.
The existing **TIKKIT** dashboards describe the API; inspect web logs/container
metrics in Explore. Do not expect frontend page-load or JavaScript-error panels.

After deployment:

1. `curl -i https://tikkit.life/api/health` must return **204**, and a deep SPA
   link must return the application. Verify Google login and a **101** WebSocket
   handshake for `/socket/websocket` in browser developer tools.
2. On the server, use the API service name from `terraform output`:

   ```sh
   docker service inspect API_SERVICE --format '{{json .Spec.UpdateConfig}}'
   docker service inspect API_SERVICE --format '{{json .Spec.TaskTemplate.Networks}}'
   docker service ps API_SERVICE --no-trunc
   docker ps --filter label=com.docker.swarm.service.name=API_SERVICE
   ```

   In an API container's Dokploy terminal:

   ```sh
   echo "$DNS_CLUSTER_QUERY"  # tasks.tikkit-api-cluster
   getent ahostsv4 "$DNS_CLUSTER_QUERY"
   export RELEASE_NODE="$(cat /tmp/tikkit-release-node)"
   /app/bin/tikkit rpc 'IO.inspect({Node.self(), Node.list()})'
   /app/bin/tikkit rpc 'Code.eval_file("/app/dokploy/cluster_ready.exs")'
   ```

   One task normally has no peers. During an update, each task must see the
   other as `tikkit@<IP>`. Do not dump the full service/container environment.
3. Keep two authenticated browser sessions open on the same project, make
   changes during **api → Deploy**, and check realtime delivery, reconnect and
   resync. Verify both peers while two tasks overlap; if the window is too short,
   temporarily use two replicas in a staging copy for a deterministic PubSub
   check. After production settles, confirm exactly one healthy API replica.
4. Generate API traffic and wait a few collection intervals. In Grafana's
   **TIKKIT** folder select **production**; inspect request counts, database/BEAM
   metrics, and traces. In Explore query:

   ```logql
   {service_name="tikkit-api", deployment_environment="production"}
   {service_name="tikkit-web", deployment_environment="production"}
   ```

   For container metrics, use
   `container_memory_working_set_bytes{service_name=~"tikkit-(api|web)",deployment_environment="production"}`.
   Follow an API log's trace link to Tempo. Missing traffic produces empty
   request panels; it is not evidence that telemetry delivery works.

## Local validation

```sh
terraform -chdir=terraform/dokploy fmt -check
terraform -chdir=terraform/dokploy validate
python3 -m unittest discover -s terraform/dokploy/tikkit -p 'test_*.py'
python3 -m unittest discover -s stacks/monitoring -p test_validate.py
python3 stacks/monitoring/validate.py  # requires running Docker and pinned images
```

These checks do not replace the live rollout/PubSub and telemetry checks above.

With Elixir/OTP and the sibling Tikkit API's compiled `phoenix_pubsub` dependency
available, this standalone test checks initial boot without task DNS, peer
readiness, bidirectional membership, an actual cross-node PubSub broadcast, and
rejection of an incorrect release identity. It uses two ephemeral local nodes,
no database, and a test-only cookie:

```sh
elixir --name tikkit-readiness-test@127.0.0.1 --cookie local-test-only \
  --erl '-kernel inet_dist_use_interface {127,0,0,1}' \
  terraform/dokploy/tikkit/test_cluster.exs
```

Set `PUBSUB_EBIN` to the compiled dependency directory if the sibling repo is
elsewhere. This tests Erlang/PubSub behavior, not Docker's overlay or rolling
update scheduler. The test node name `tikkit@127.0.0.1` must be free locally.

## References

- [Pinned provider Application schema](https://github.com/AhmedAli6/terraform-provider-dokploy/blob/v0.8.0/docs/resources/application.md)
- [Pinned provider domain schema](https://github.com/AhmedAli6/terraform-provider-dokploy/blob/v0.8.0/docs/resources/domain.md)
- [Dokploy advanced/Swarm settings](https://docs.dokploy.com/docs/core/applications/advanced)
- [Dokploy shared environment references](https://docs.dokploy.com/docs/core/variables)
- [Docker Swarm health and service binding](https://github.com/moby/moby/blob/master/daemon/cluster/executor/container/controller.go)
- [DNSCluster discovery and node names](https://hexdocs.pm/dns_cluster/DNSCluster.html)
- [Monitoring runbook](../../../../stacks/monitoring/README.md)
