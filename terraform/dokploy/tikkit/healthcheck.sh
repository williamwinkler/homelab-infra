#!/bin/sh
set -eu

curl --fail --silent --show-error --max-time 3 http://127.0.0.1:4000/api/health

# Gate the first healthy result on connectivity to existing PubSub peers.
# Subsequent checks remain HTTP+DB checks so a departing peer cannot kill the
# surviving task. Every replacement task starts with an empty readiness marker.
if [ ! -f /tmp/tikkit-cluster-ready ]; then
  RELEASE_NODE=$(cat /tmp/tikkit-release-node)
  export RELEASE_NODE
  /app/bin/tikkit rpc 'Code.eval_file("/app/dokploy/cluster_ready.exs")'
  touch /tmp/tikkit-cluster-ready
fi
