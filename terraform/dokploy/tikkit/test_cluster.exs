# Standalone test using the sibling app's compiled Phoenix.PubSub dependency.
# Creates only ephemeral local nodes; no database or live service is used.
check = Path.join(__DIR__, "cluster_ready.exs")

pubsub_ebin =
  System.get_env("PUBSUB_EBIN") ||
    Path.expand("../../../../tikkit/apps/api/_build/dev/lib/phoenix_pubsub/ebin", __DIR__)

Code.prepend_path(pubsub_ebin)
{:ok, _} = Application.ensure_all_started(:phoenix_pubsub)
{:ok, _} = Supervisor.start_link([{Phoenix.PubSub, name: Tikkit.PubSub}], strategy: :one_for_one)
System.put_env("RELEASE_NODE", Atom.to_string(Node.self()))
System.put_env("DNS_CLUSTER_QUERY", "tasks.tikkit-readiness-test")
:inet_db.set_lookup([:file])
# No published task yet: initial deployment must be able to become healthy.
Code.eval_file(check)
IO.puts("PASS: first deployment without published task DNS")

{:ok, controller, peer} =
  :peer.start_link(%{
    name: :"tikkit@127.0.0.1",
    longnames: true,
    connection: :standard_io,
    args: [
      ~c"-setcookie",
      Atom.to_charlist(Node.get_cookie()),
      ~c"-kernel",
      ~c"inet_dist_use_interface",
      ~c"{127,0,0,1}",
      ~c"-pa" | :code.get_path()
    ]
  })

try do
  {:ok, _} = :erpc.call(peer, Application, :ensure_all_started, [:phoenix_pubsub])
  :ok = :inet_db.add_host({127, 0, 0, 1}, [~c"tasks.tikkit-readiness-test"])

  try do
    Code.eval_file(check)
    raise "Expected rejection before remote PubSub starts"
  rescue
    e in RuntimeError ->
      unless String.contains?(e.message, "Discovered PubSub peer is not ready"),
        do: reraise(e, __STACKTRACE__)
  end

  IO.puts("PASS: connected node without PubSub is rejected")
  # Keep the PubSub supervisor linked to a persistent owner on the remote node.
  parent = self()

  :erpc.call(peer, Code, :eval_string, [
    ~S"""
    spawn(fn ->
      {:ok, _} = Supervisor.start_link([{Phoenix.PubSub, name: Tikkit.PubSub}], strategy: :one_for_one)
      :ok = Phoenix.PubSub.subscribe(Tikkit.PubSub, "deployment-smoke")
      send(parent, :peer_ready)
      receive do
        :probe -> send(parent, :pubsub_received)
      after
        15_000 -> :timeout
      end
      receive do :stop -> :ok after 15_000 -> :timeout end
    end)
    """,
    [parent: parent]
  ])

  receive do
    :peer_ready -> :ok
  after
    5_000 -> raise "Peer failed to start"
  end

  Enum.reduce_while(1..30, nil, fn _, _ ->
    try do
      Code.eval_file(check)
      {:halt, :ok}
    rescue
      _ ->
        Process.sleep(100)
        {:cont, nil}
    end
  end) == :ok || raise "Membership failed to converge"

  IO.puts("PASS: two-node PubSub membership becomes ready")
  :ok = Phoenix.PubSub.broadcast(Tikkit.PubSub, "deployment-smoke", :probe)

  receive do
    :pubsub_received -> IO.puts("PASS: cross-node PubSub broadcast received")
  after
    5_000 -> raise "Broadcast did not arrive"
  end

  System.put_env("RELEASE_NODE", "wrong@127.0.0.1")

  try do
    Code.eval_file(check)
    raise "Expected identity rejection"
  rescue
    e in RuntimeError ->
      unless String.contains?(e.message, "Release distribution must use"),
        do: reraise(e, __STACKTRACE__)
  end

  IO.puts("PASS: wrong release identity is rejected")
after
  :peer.stop(controller)
end
