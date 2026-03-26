---
name: server
repo: https://github.com/bradgessler/expomator
local_path: /Users/bradgessler/Projects/expomator/server
stack: Rails edge, Ruby 3.4, SQLite3, Tailwind CSS, Falcon (async server)
complexity: low
---

# Expomator Server

Rails edge app with SQLite3, Tailwind CSS, Falcon async server. Simple stack - no external databases.

## Success

- Dockerfile: ruby:3.4 base, nodejs for assets
- Services: none required (SQLite is file-based)
- Dev command: `bin/dev` or `falcon serve` with port 3000 exposed
- After rebuild: `bundle install`, `rails db:prepare`
- Dev server responds on its port
- 11/11 checklist items

## Gotchas

- **`hotswap` gem crashes with socket error** — The `hotswap` gem tries to create a Unix socket at `/workspace/tmp/sockets/hotswap.sock`. Unix sockets don't work across Docker bind mounts. Fix: set `HOTSWAP_DISABLED=1` env var via `set_env_vars`.
- **`.ruby-version` mismatch** — Project specifies ruby 3.4.2 but cached image is 3.4.8. After first rebuild, exec `echo "3.4.8" > .ruby-version` then rebuild again. Otherwise Bundler crashes with RubyVersionMismatch.
- **Use ruby:3.4.8-slim** — This is the only cached ruby image. Other versions hang on Docker pull.
- Uses Rails edge from github main branch — `bundle install` may need extra time
- Uses Falcon async server instead of Puma — check Procfile.dev for correct command
- CSS watcher needs polling mode (`TAILWINDCSS_POLL=true`) for bind mount file watching
- No external services needed — SQLite3 is file-based, stored in db/*.sqlite3
