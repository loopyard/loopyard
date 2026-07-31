import Config

# Where we listen is a BOOT FLAG, not runtime state:
#
#   LOOPYARD_BIND=0.0.0.0    reachable on the LAN
#   (unset)                  loopback only
#
# This replaced a UI toggle that could strand you: it was reachable over the
# very connection it controlled, so hitting "private" from your phone while
# travelling severed your only link with no way back short of physical access.
# It also persisted to a JSON file, so losing that file silently un-exposed the
# server. Parsed inline (not via Loopyard.Bind) because config is evaluated
# before app modules are guaranteed loaded; Loopyard.Bind reads it back for
# display. Bad values fall back to loopback — the safe direction.
bind_ip =
  case System.get_env("LOOPYARD_BIND") do
    nil ->
      {127, 0, 0, 1}

    val ->
      case :inet.parse_strict_address(String.to_charlist(String.trim(val))) do
        {:ok, ip} -> ip
        {:error, _} -> {127, 0, 0, 1}
      end
  end

config :loopyard, LoopyardWeb.Endpoint,
  http: [ip: bind_ip, port: String.to_integer(System.get_env("PORT") || "4000")],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base:
    "dev_secret_key_base_that_is_at_least_64_bytes_long_for_hive_application_dev_mode",
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:loopyard, ~w(--sourcemap=inline --watch)]},
    tailwind: {Tailwind, :install_and_run, [:loopyard, ~w(--watch)]}
  ]

config :loopyard, LoopyardWeb.Endpoint,
  live_reload: [
    patterns: [
      ~r"priv/static/(?!uploads/).*(js|css|png|jpeg|jpg|gif|svg)$",
      ~r"lib/loopyard_web/(controllers|live|components)/.*(ex|heex)$"
    ]
  ]

config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime

# Model the coding agents run on. Alias ("sonnet"/"opus"/"haiku"/"fable") or a
# full model id. Unset → SDK default ("sonnet"). Change + restart to switch the
# whole instance — that's the entire "changing models" cost.
config :loopyard, agent_model: "claude-fable-5"
