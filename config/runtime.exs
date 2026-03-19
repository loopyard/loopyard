import Config

# Load .env file if present (dev/test convenience, not used in prod deploys)
if config_env() in [:dev, :test] do
  Dotenvy.source([".env", ".env.#{config_env()}"])
end

# --- 12-Factor Configuration ---
# All runtime config comes from environment variables.

# Auth — set BOOM_LOOPER_AUTH_PASSWORD to enable HTTP Basic Auth
# BOOM_LOOPER_AUTH_USERNAME is optional (defaults to accepting any username)
config :boom_looper,
  auth_password: System.get_env("BOOM_LOOPER_AUTH_PASSWORD"),
  auth_username: System.get_env("BOOM_LOOPER_AUTH_USERNAME")

if config_env() == :prod do
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"
  port = String.to_integer(System.get_env("PORT") || "4000")

  config :boom_looper, BoomLooperWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}, port: port],
    secret_key_base: secret_key_base
end
