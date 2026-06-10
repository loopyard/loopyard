# The Loopyard work-container base image — the cheap, code-mounted box an
# agent works in (see Loopyard.Workspace.WorkContainer). It is also the
# **harness host**: the real Claude/Codex harness runs *inside* this container
# via ACP (`docker exec -i <work> claude-code-acp`), against the mounted code
# volume. That's the north star — the box hosts a real harness, it doesn't
# reimplement one. New harnesses plug in by adding their adapter here; nothing
# else about the sandbox changes.
FROM alpine:3.19

# Essential tools for workspace operations (git ingress, shell, sync).
RUN apk add --no-cache \
    git \
    github-cli \
    openssh-client \
    bash \
    curl \
    rsync \
    nodejs \
    npm

# The ACP harness adapter(s). `@zed-industries/claude-code-acp` wraps the
# Claude Agent SDK as an ACP server over stdio — this is what makes the REAL
# harness (native tools, skills, subagents) run in the box. Pinned for
# reproducibility; bump deliberately. Codex's adapter is added here the same
# way when that backend lands (harness-agnostic by construction).
RUN npm install -g @zed-industries/claude-code-acp@0.16.2

WORKDIR /workspace

CMD ["sleep", "infinity"]
