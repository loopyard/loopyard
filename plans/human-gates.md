# Human-in-the-Loop Gates: approval workflows for agent tool calls

## Problem

Agents should be able to request sensitive operations (secrets, deployments, database access, external API calls) but a human must explicitly approve each request. The agent can't bypass the gate — it's not a "are you sure?" dialog, it's a hard block that requires human action to proceed.

## Core concept

Any MCP tool can declare that it requires human approval. When the agent calls that tool, the call pauses, the human gets notified, and the agent waits. The human sees exactly what's being requested, approves or denies, and the tool completes or rejects.

From the agent's perspective, it's just a slow tool call. From the human's perspective, it's a notification with context and an approve/deny button.

## Examples

### Secrets
```
Agent: "I need the Stripe API key to configure payments"
→ calls get_secret(key: "STRIPE_API_KEY")
→ GATE: "Agent 'Setup' wants to access secret STRIPE_API_KEY"
→ Human approves
→ Agent receives the key, continues
```

### New secret creation
```
Agent: "I need to add a new DATABASE_URL secret"
→ calls set_secret(key: "DATABASE_URL", value: "postgres://...")
→ GATE: "Agent 'Setup' wants to create secret DATABASE_URL"
→ Human reviews the value, approves
→ Secret is stored
```

### Destructive operations
```
Agent: "I'll reset the database and re-run migrations"
→ calls exec(command: "rails db:reset")
→ GATE: "Agent 'Developer' wants to run: rails db:reset (destructive)"
→ Human approves or says "no, just run migrations"
```

### External network access
```
Agent: "I need to install this npm package"
→ calls exec(command: "npm install stripe")
→ GATE: "Agent wants to install package 'stripe' from npm"
→ Human approves
```

## Architecture

### Gate declaration

Tools declare gates via the `Loopyard.Tool` macro:

```elixir
defmodule Loopyard.Tools.Secrets.GetSecret do
  use Loopyard.Tool,
    name: "get_secret",
    description: "Retrieve a secret value",
    gate: :approve,  # :approve, :notify, or nil (no gate)
    gate_message: fn params -> "Access secret: #{params.key}" end,
    params: [
      agent_id: {:string, required: true},
      key: {:string, required: true}
    ]
```

Gate types:
- **`:approve`** — hard block. Agent waits. Human must approve or deny.
- **`:notify`** — soft notification. Agent proceeds but human is informed.
- **`nil`** — no gate (default, current behavior).

### Gate execution flow

```
Agent calls tool
  ↓
Tool.execute checks for gate
  ↓
If gate == :approve:
  1. Create a GateRequest in ETS (id, agent_id, tool, params, status: :pending)
  2. Broadcast {:gate_request, request} via PubSub
  3. Block (GenServer.call with :infinity timeout, or a Task that waits)
  4. LiveView shows notification with approve/deny buttons
  5. Human clicks approve → GateRequest status: :approved → unblock
  6. Human clicks deny → GateRequest status: :denied → return {:error, "Denied by operator"}
  7. Tool.execute continues with the original params
  ↓
Return result to agent
```

### LiveView integration

The gate notification appears as a modal/toast in the chat:

```
┌─────────────────────────────────────────┐
│ 🔒 Approval Required                    │
│                                          │
│ Agent "Setup" wants to:                  │
│ Access secret: STRIPE_API_KEY            │
│                                          │
│ Context: Setting up payment processing   │
│ for the e-commerce checkout flow.        │
│                                          │
│    [ Deny ]              [ Approve ]     │
└─────────────────────────────────────────┘
```

On mobile, this could also be a push notification. The approval URL is stable (like `/gates/:id/approve`) so it could be sent via SMS, Slack webhook, or email.

### Gate policies (per agent type)

Different agent types have different gate policies:

```elixir
%AgentType{
  name: "Setup",
  tool_servers: ["loopyard-container", "loopyard-secrets"],
  gates: %{
    "get_secret" => :approve,     # must approve each secret access
    "set_secret" => :approve,     # must approve secret creation
    "docker_compose" => nil,      # no gate — setup needs this freely
    "exec" => :notify             # notify but don't block
  }
}
```

Gates can be:
- **Per tool** — `get_secret` always requires approval
- **Per agent type** — "Setup" agents can exec freely, "QA" agents need approval for exec
- **Per pattern** — exec commands matching `rm -rf` or `DROP TABLE` require approval regardless of agent type
- **Per project** — production-adjacent projects have stricter gates than dev playgrounds

### Gate context

The approval UI should show WHY the agent wants access, not just WHAT it's requesting. The gate request includes:

- The agent's name and what it's working on
- The last few messages of conversation (so the human has context)
- The exact tool call params
- A "reason" field the agent can optionally fill in

### Timeout and expiry

- Gate requests expire after a configurable timeout (default: 5 minutes)
- Expired gates return `{:error, "Approval timed out"}` to the agent
- The agent can try again or ask the human directly
- Multiple pending gates from the same agent are shown as a batch

### Audit log

Every gate decision is logged:
- Who approved/denied
- When
- What was requested
- What agent, what project, what workspace
- The conversation context at the time

This is the foundation for compliance — "who authorized this agent to access production credentials?"

## Implementation order

1. **GateRequest struct + ETS table** — pending/approved/denied states
2. **Gate middleware in Tool execution** — check gate declaration, block if needed
3. **PubSub broadcast** — notify LiveViews of pending gates
4. **Chat UI** — modal/inline approval widget
5. **Gate policies on agent types** — per-type gate configuration
6. **Pattern-based gates** — regex matching on exec commands
7. **External notifications** — Slack/email/SMS for mobile approval
8. **Audit log** — persistent record of all gate decisions

## Connection to agent types

This builds directly on the agent types plan. Agent types define:
- Name
- Tool servers (which MCPs the agent gets)
- **Gate policies** (which tools need approval for this agent type)
- System prompt

The "New Agent" flow becomes: pick a name, pick tools, configure gates, launch. Presets bundle all three.

## Security properties

- **Hard block** — the agent CANNOT get the secret/run the command without approval. It's not a client-side check that can be bypassed.
- **Per-invocation** — approving "get STRIPE_API_KEY" once doesn't approve it forever. Each call goes through the gate.
- **Auditable** — every decision is logged with full context.
- **Composable** — gates are declared per-tool and configured per-agent-type. Adding a new sensitive tool means adding `gate: :approve` to the macro.
