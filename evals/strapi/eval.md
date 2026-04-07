---
title: Strapi
git_url: https://github.com/strapi/strapi.git
branch: develop
---

Headless CMS, Node.js + monorepo (yarn workspaces). Tests the setup agent against a non-Next.js Node app: dev server is `yarn develop` from one of the example apps in `/examples/getstarted`, default port 1337, sqlite as the default database (no separate DB service needed). The agent has to figure out monorepo navigation and pick the right workspace to run.
