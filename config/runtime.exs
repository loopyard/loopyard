import Config

# Load .env file if present (dev/test convenience, not used in prod deploys)
if config_env() in [:dev, :test] do
  Dotenvy.source([".env", ".env.#{config_env()}"])
end

# --- 12-Factor Configuration ---
# All runtime config comes from environment variables.

# Auth — set LOOPYARD_AUTH_PASSWORD to enable HTTP Basic Auth
# LOOPYARD_AUTH_USERNAME is optional (defaults to accepting any username)
config :loopyard,
  auth_password: System.get_env("LOOPYARD_AUTH_PASSWORD"),
  auth_username: System.get_env("LOOPYARD_AUTH_USERNAME")

# Releases do not start the endpoint unless told to. The server image sets this;
# an embedded/desktop release that wants the app without a listener does not.
if System.get_env("PHX_SERVER") do
  config :loopyard, LoopyardWeb.Endpoint, server: true
end

if config_env() == :prod do
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"
  port = String.to_integer(System.get_env("PORT") || "4000")

  # IPv4 wildcard — see comment in config/dev.exs for why we don't use IPv6.
  config :loopyard, LoopyardWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [ip: {0, 0, 0, 0}, port: port],
    secret_key_base: secret_key_base
end
