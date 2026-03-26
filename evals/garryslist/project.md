---
name: garryslist
repo: https://github.com/bradgessler/garryslist
local_path: /Users/bradgessler/Projects/Garry-s-List/garryslist
stack: Rails 8, Ruby 3.4, PostgreSQL (PostGIS), Redis, Tailwind CSS, Node.js
complexity: medium
---

# Garry's List

Rails 8 app with PostGIS, Redis, Tailwind CSS. Uses `bin/dev` (foreman) to start web + CSS watcher + JS bundler.

## What success looks like

- Dockerfile: ruby:3.4 base, system deps (libpq-dev, nodejs, etc.)
- Services: postgres (postgis image), redis
- Dev command: `bin/dev` with port 5000 exposed
- After rebuild: `bundle install`, `npm install`, `npm rebuild`, `bin/rails db:create db:migrate`
- Dev server responds on its port
- 11/11 checklist items

## Known gotchas

- Needs PostGIS-enabled postgres image, not plain postgres
- May also need pgvector — use an image with both or install via Dockerfile
- CSS watcher needs polling mode (`TAILWINDCSS_POLL=true`) for bind mount file watching
- `bin/dev` uses foreman which needs to be installed in the image
- esbuild binary from host node_modules won't work in container — needs `npm rebuild`
- Database must be created before migrations (`rails db:create`)
