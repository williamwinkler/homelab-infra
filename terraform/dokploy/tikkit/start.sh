#!/bin/sh
set -eu

# Swarm publishes service DNS only AFTER health succeeds. Select the local
# cluster-overlay IP by subnet, without waiting for this task's DNS record.
: "${TIKKIT_CLUSTER_IP_PREFIX:?Cluster overlay IPv4 prefix is required}"
task_ip=
for candidate in $(hostname -i); do
  case "$candidate" in
    "$TIKKIT_CLUSTER_IP_PREFIX"*)
      if [ -n "$task_ip" ]; then
        echo "Multiple local addresses match the cluster overlay" >&2
        exit 1
      fi
      task_ip="$candidate"
      ;;
  esac
done

if [ -z "$task_ip" ]; then
  echo "No local task IP found on cluster overlay $TIKKIT_CLUSTER_IP_PREFIX" >&2
  exit 1
fi

export RELEASE_NODE="tikkit@$task_ip"
printf '%s\n' "$RELEASE_NODE" > /tmp/tikkit-release-node
# A container restart keeps /tmp; check readiness again for each BEAM.
rm -f /tmp/tikkit-cluster-ready
exec /app/bin/server
