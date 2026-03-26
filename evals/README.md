# Evals

Test BoomLooper's setup agent against real projects. Track what works, what breaks, and what prompt changes fix it.

## Structure

```
evals/
├── projects/          # Project definitions (what to set up)
│   └── garryslist.md  # Stack, gotchas, success criteria
├── runs/              # Run logs (what happened)
│   └── garryslist-2026-03-25.md  # Timestamped run with frontmatter
└── README.md
```

## Project files (`evals/projects/*.md`)

Define a project to test against:

```yaml
---
name: garryslist
repo: https://github.com/bradgessler/garryslist
local_path: /Users/bradgessler/Projects/Garry-s-List/garryslist
stack: Rails 8, Ruby 3.4, PostgreSQL, Redis
complexity: medium
---
```

Include known gotchas and what a successful setup looks like.

## Run files (`evals/runs/*.md`)

Record what happened during a setup attempt:

```yaml
---
project: garryslist
started_at: 2026-03-25T22:58:00Z
finished_at: 2026-03-26T06:10:00Z
result: success | partial | failed
agent_id: bbf2cb18947d34af
tool_calls: 123
errors: 2
checklist_completed: 8/11
prompt_version: setup_guide_v1
---
```

Body should include: what worked, what failed, root causes, and prompt changes needed.

## Eval loop

1. Pick a project from `evals/projects/`
2. Launch it in BoomLooper
3. Monitor the setup agent via IEx RPC
4. Record the run in `evals/runs/`
5. Apply prompt fixes from the run log
6. Tear down, retry
