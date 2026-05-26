ExUnit.start()

# Many tests need a PubSub server (Channel broadcasts on whatever
# Aural.pubsub/0 returns). Start one for the test run and point the
# package at it.
{:ok, _} = Phoenix.PubSub.Supervisor.start_link(name: Aural.TestPubSub)
Application.put_env(:aural, :pubsub, Aural.TestPubSub)

# Keep idle-reap behavior testable without 5-minute waits.
Application.put_env(:aural, :idle_timeout_seconds, 300)
