# Changelog

## Unreleased

### Added
- EvalRunner HTTP probing — declares success on 2xx, feeds error response bodies back to agent
- Post-rebuild status report — agent gets service status, crash logs, and HTTP probe results after every rebuild
- SSH server for terminal access to containers (`ssh -p 2222 container@localhost`)
- `/connect` page with LAN QR code for mobile access
- `StreamBuffer` module for streaming output accumulation
- `LogViewer` components (`log_panel`, `log_inline`, `log_multi_service`)
- Terminal multiplayer clear (Cmd+K / Ctrl+L broadcasts to all viewers)
- TailScroll pause-on-scroll-up behavior for chat and logs
- Mobile responsive layout (sidebar hides on mobile, back button navigation)
- Safari iOS fixes (dvh viewport, safe area insets, content overflow)
- GitHub Actions CI
- PR template with checklist

### Fixed
- `mix loopyard.setup` now supports Homebrew 6.0.10, isolates Hex installation from dependency resolution, installs JavaScript dependencies, and stops on failed steps
- Rebuild messages now reach the agent (was broadcasting to PubSub only, agent never subscribed to its own topic)
- `append_external_message` now broadcasts to PubSub so both agent and LiveView subscribers see external messages

### Changed
- `.hive/` renamed to `.boomlooper/` with `repo/` (tracked) and `workspace/` (gitignored) split
- `branch` terminology renamed to `workspace` throughout
- URLs changed to `/projects/:id/workspaces/:id/agents/:id` and `/messages/:agent_id/:msg_id`
- User messages now flow through PubSub (fixes multiplayer visibility)
- Terminal PubSub topic changed to `terminal_output:` (fixes double-echo)
- Chat scroll only auto-scrolls when user is at the bottom
- Server binds to all interfaces by default (LAN access always on)
- `BOOMLOOPER_HOME` env var for user-level data directory

### Removed
- WireGuard VPN module (too much user friction)
- Optimistic message adds (broke multiplayer)
- `stty -echo` terminal hacks (root cause was PubSub collision, not PTY echo)
