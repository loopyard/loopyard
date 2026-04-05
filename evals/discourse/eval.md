---
title: Discourse
git_url: https://github.com/discourse/discourse.git
---

Large Rails forum application. Stress-tests the setup agent with a complex dependency tree: Ruby, Node.js, PostgreSQL, Redis, and extensive system packages.

Expects: Dockerfile with Ruby + Node base, postgres and redis services, dev command with correct port binding. Discourse uses `bin/ember-cli` for frontend and `bin/rails server` for backend.
