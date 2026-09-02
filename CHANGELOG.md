# Changelog

## Unreleased

### Added
- Chat attachments — attach screenshots/files to a message via the paperclip, paste, or drag-and-drop onto the chat (up to 10 per message, 25 MB each). Files land in the workspace volume at `.loopyard/uploads/` (self-gitignored) and reach the agent as `📎 Attached: <path>` lines — and, on a harness that accepts image blocks (Claude's ACP adapter does), the images themselves ride inline in the prompt so the model sees them without a Read; the transcript shows thumbnails, served by `/projects/:p/workspaces/:w/attachments/:name`. The Operator takes attachments too (stored in its workstation `$HOME`, served by `/operator/attachments/:name`). Hardened: images are typed by magic number (a HEIC is converted to JPEG), only files in the uploads dir are ever inlined, 20 MB per prompt, the route serves non-images as sandboxed downloads, a held Send won't fire without its file, rich pastes keep their text, and a vanished image falls back to its name.
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

### Changed
- Docs reconciled against the code (Sept 2026): CLAUDE.md, ARCHITECTURE, SECURITY, CONFIG, TESTING, CODE_RULES, SOURCE_ADAPTERS, EVALS, HOSTING and IMPROVEMENTS each audited claim-by-claim; stale machinery (`Harness.Claude`, `/system/reset`, `/remote`, `/queue`, the three-token chat scale, `session_opts_with_resume/1`, `code-<id>` volumes, the "no `session/cancel`" and "unbounded buffer" gaps) removed or corrected; 17 undocumented config keys, 7 env vars and 7 on-disk files added to CONFIG.md; the canonical deck URL is `/notifications`; 12 merged/superseded plans moved to `plans/archive/`.
- Static analysis is now enforced, not reported: `mix credo --strict`, `mix sobelow --config` and `mix dialyzer` are hard CI gates against a clean baseline (they had been `continue-on-error` since day one, hiding 120 credo issues, 6 sobelow findings and 82 dialyzer warnings). Credo gained the checks that catch silent production bugs (`UnsafeToAtom`, `UnsafeExec`, `Dbg`, `MixEnv`, `ApplicationConfigInModuleAttribute`, `WrongTestFileExtension`, `MapGetUnsafePass`, `SpecWithStruct`); structure checks (complexity, nesting, arity, TODO) are report-only. Dialyzer's PLT lives in `priv/plts` so CI's cache actually hits.

### Fixed
- The agent prompt told agents to run a `service_status` tool that doesn't exist; it's `service_containers`.
- The SSH daemon (on by default, unauthenticated by design) bound every interface; it now follows `LOOPYARD_BIND` like the web endpoint — loopback unless you opt in.
- Two container tools opened raw Docker ports past the daemon gate; two LiveView handlers blocked on Docker; a component hand-built container names that break under the configurable prefix; `Operator.Queue` imported a web component; `Node.start/2` used the pre-1.19 argument form; `enqueue_message/2`'s spec omitted `:queue_full`; a music tool passed a string where `Aural.Channel.pick_track/2` wants an atom. All found by the rule audit and dialyzer.
- Test suite audit (Sept 2026): CI has been red since Aug 18 on the reviewer showcase scene (mock slides predated the deck's `key`); fixed. Agent tests no longer share the checkout's workspace group (the "no process" flake under load) — `Loopyard.AgentCase` gives each module its own. `VolumeIO.mirror_dir` honours the Docker daemon gate, which was spawning the real CLI on every agent boot in tests: agent suites 47 s → 19 s. New coverage for `Operator.Digest`, the chat nav/status, setup-progress and sync-detail components; pure modules run async. Second pass: the three production waits a test doesn't need (sync readiness probe, warm-interrupt deadline, rate-limit grace) are test-env knobs, fixed sleeps in the agent tests became event waits (`TestHelpers.eventually/2`), the whole-project recompile test is `:slow`, and `/workstations` got mount tests.
- Integration pages live-update when a credential is pushed by `curl` — env and file writes now broadcast on a per-workstation topic instead of leaving the badge on its mount-time answer
- Mac transfer scripts say why they did nothing (not installed / not logged in) instead of silently short-circuiting and leaving the page reading "Not connected"
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
