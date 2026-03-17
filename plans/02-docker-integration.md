---
title: Docker Integration
status: planned
depends_on: []
---

# Docker Integration

Run each agent's Claude Code session inside a Docker container. The container is the security sandbox — no permission prompts, no host filesystem access.

## What to build

- Base Dockerfile with claude CLI + common dev tools (git, node, python)
- Configurable Dockerfiles per agent (agent can edit its own Dockerfile and rebuild)
- ChatAgent spawns claude inside Docker instead of locally
- Port mapping for web servers the agent starts
- Volume mounts for persistent project files

## Docker lifecycle

```
Agent created → docker run → claude CLI started inside
Agent message → SDK talks to claude over stdin/stdout (via docker exec or attached)
Agent stopped → docker stop → docker rm
```

## Open questions

- How does the SDK talk to claude inside Docker? Options:
  - Run `docker exec` as the CLI command the SDK spawns
  - Attach to container stdin/stdout directly
- Port allocation: Docker random port mapping (`-P`) vs static range
- File persistence: named volumes or bind mounts?
- Base image registry: local build only, or push to registry?

## Acceptance criteria

- [ ] Agent spawns inside a Docker container
- [ ] Agent can run bash commands in the container
- [ ] Agent can start a web server with a port accessible from the host
- [ ] Agent can edit its own Dockerfile and rebuild
- [ ] Container is destroyed when agent stops
- [ ] Tests for container lifecycle (with Docker daemon)
