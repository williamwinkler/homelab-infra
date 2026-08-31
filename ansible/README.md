# Ansible

## Install ansible

```zsh
brew install ansible
```

## Run server playbooks

```zsh
ansible-playbook playbooks/update_packages.yml -i inventory --ask-become-pass
```

## Prepare the observability overlay

Run this on the Dokploy server before deploying the Monitoring Swarm Stack. It
creates `observability` as an attachable overlay so Dokploy Application services
can reach Alloy. It fails if the old Compose bridge with the same name still
exists; stop and remove that retired deployment first.

```zsh
ansible-playbook playbooks/create_observability_network.yml \
  -i inventory --ask-become-pass
```

## Configure friendly homelab names on a Mac

Run this locally on each managed MacBook. It creates one clearly marked,
idempotent block in `/etc/hosts`; it does not SSH to or modify the Dokploy
server.

The Dokploy server's canonical MagicDNS name and Tailscale IPv4 address live
in [`vars/homelab.yml`](vars/homelab.yml). Update the IPv4 value only if that
Tailscale node is recreated.

```zsh
ansible-playbook playbooks/configure_homelab_hosts.yml --ask-become-pass
```

This makes `http://grafana.home.arpa` and `http://prometheus.home.arpa` resolve
to the Dokploy server's Tailscale IP. The names must match Terraform's
`monitoring.grafana_host` and `monitoring.prometheus_host` values so Traefik
routes each request to the intended service.
