# Evals

Test BoomLooper's setup agent against real projects.

## Structure

```
evals/
├── garryslist/
│   ├── project.md           # Stack, gotchas, success criteria
│   ├── 2026-03-25.md        # Run log
│   └── 2026-03-26.md        # Another run after prompt fixes
├── another-project/
│   ├── project.md
│   └── ...
└── README.md
```

## `project.md` frontmatter

```yaml
---
name: garryslist
repo: https://github.com/user/repo
local_path: /path/to/local/clone
stack: Rails 8, Ruby 3.4, PostgreSQL
complexity: easy | medium | hard
---
```

## Run log frontmatter

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
