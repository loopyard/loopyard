---
name: garryslist
repo: https://github.com/bradgessler/garryslist
local_path: /Users/bradgessler/Projects/Garry-s-List/garryslist
stack: Rails 8, Ruby 3.4, PostgreSQL (PostGIS), Redis, Tailwind CSS, Node.js
complexity: medium
notes: Has PostGIS extension, Procfile.dev with CSS watcher, production Dockerfile (not dev)
---

# Garry's List

Rails 8 app with PostGIS, Redis, Tailwind CSS. Uses `bin/dev` (foreman) to start web + CSS watcher + JS bundler.

## What a successful setup looks like

- Dockerfile: ruby:3.4 base, system deps (libpq-dev, nodejs, etc.)
- Services: postgres (postgis image), redis
- Dev command: `bin/dev` or adapted foreman command with `--poll` for CSS watcher
- After rebuild: `bundle install`, `npm install`, `bin/rails db:setup`
- Dev server responds on its port

## Known gotchas

- Needs PostGIS-enabled postgres image, not plain postgres
- CSS watcher needs `--poll` for bind mount file watching
- `bin/dev` uses foreman which needs to be installed
- Database config expects `POSTGRES_PASSWORD` env var
