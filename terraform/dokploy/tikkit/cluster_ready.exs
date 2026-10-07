# Evaluated through release RPC inside the running application, not a new node.
query = System.fetch_env!("DNS_CLUSTER_QUERY") |> String.to_charlist()

addresses =
  case :inet.getaddrs(query, :inet) do
    {:ok, addresses} -> addresses
    # First deployment has no healthy tasks yet, hence no tasks DNS record.
    {:error, :nxdomain} -> []
    {:error, reason} -> raise "Cluster DNS lookup failed: #{inspect(reason)}"
  end

nodes = Enum.map(addresses, &String.to_atom("tikkit@#{:inet.ntoa(&1)}"))

unless Node.alive?() and Atom.to_string(Node.self()) == System.fetch_env!("RELEASE_NODE") do
  raise "Release distribution must use this task's cluster-overlay address"
end

unless is_pid(Process.whereis(Tikkit.PubSub)) do
  raise "Local PubSub is not ready"
end

for peer <- Enum.uniq(nodes), peer != Node.self() do
  unless Node.connect(peer) and
           is_pid(:erpc.call(peer, Process, :whereis, [Tikkit.PubSub], 2_000)) do
    raise "Discovered PubSub peer is not ready: #{peer}"
  end

  # Tikkit uses Phoenix's default PG2 adapter and one pool partition. A node
  # connection alone can precede :pg membership synchronization.
  group = Tikkit.PubSub.Adapter
  local_members = :pg.get_members(Phoenix.PubSub, group)
  remote_members = :erpc.call(peer, :pg, :get_members, [Phoenix.PubSub, group], 2_000)

  unless Enum.any?(local_members, &(node(&1) == peer)) and
           Enum.any?(remote_members, &(node(&1) == Node.self())) do
    raise "PubSub membership has not converged with #{peer}"
  end
end
