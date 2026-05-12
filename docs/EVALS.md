# Evals

Evals test whether the setup agent can configure a project from scratch. Each eval lives in `evals/<name>/` with this structure:

```
evals/<name>/
  eval.md          # config (frontmatter: title, git_url) + description — tracked in git
  runs/            # timestamped result files — tracked in git
  project/         # cloned project source — gitignored, machine-local
```

```bash
mix loopyard.rpc 'BoomLooper.EvalRunner.eval("maybe-finance")'  # by name
mix loopyard.rpc 'BoomLooper.EvalRunner.list_evals()'           # list all
mix loopyard.rpc 'BoomLooper.EvalRunner.status()'               # check progress
```

Every eval starts fresh (tears down existing project first via `remove_project` — the same path real users hit). Configs and run results are tracked in git; project clones are gitignored. When an eval fails, fix the **prompts** or **tools**, not the eval target. See `/eval` skill for details.

## Evals go through the Local code path

Evals clone a git URL using the **host's git binary** into `evals/<name>/project/`, then call `ProjectRegistry.add(project_path)` — registering it as a **Local project**. From that point on, the eval exercises exactly the same code as a real user adding a local project.

**Why this matters:** evals are our integration test harness for the Local path. Every eval run implicitly tests `Source.Local`, `remove_project`, workspace creation, volume seeding, and container lifecycle. If the Local path has a resource leak, evals will catch it.

**What evals must NOT do:**
- Ad-hoc cleanup (manually stopping workspaces, deleting volumes, wiping agents.log). Call `remove_project` instead — it dispatches through the Source adapter where the tested cleanup logic lives.
- Use `add_from_url` — that's the (future) GitHub adapter path. Evals clone on the host and register as Local.
- Shell out to docker directly for anything remove_project already handles.

## Eval integrity: no nudges, no overfitting

**An eval only passes with zero human intervention.** If you have to manually send a message to kick the agent ("run bundle install", "continue"), that's a failure. The system must be autonomous enough to complete setup without nudges.

**No technology-specific code in the system.** The core BoomLooper code (GenServers, tools, compose generation) must be language-agnostic. Don't hard-code Rails commands, Python paths, or Node conventions. Examples in prompts are fine (they teach patterns), but system logic must work for any stack.

**Signs of overfitting:**
- All evals use the same language/framework (currently all Ruby/Rails — need Python, Node, Go, etc.)
- String matching for specific error messages ("bundle install failed")
- Hard-coded paths like `/usr/local/bundle` (Ruby-specific)
- Fixes that only work for the project you're debugging

**The right pattern:**
- System sends generic signals ("Continue.") and lets Claude decide what to do
- Agent reads the codebase to discover what stack it is (Gemfile → Ruby, package.json → Node, etc.)
- Agent writes technology-specific system_prompt based on what it discovers
- Prompts in `priv/prompts/` teach general patterns with examples from multiple ecosystems

**When fixing eval failures:**
1. Don't nudge the agent — that's cheating
2. Don't add project-specific logic to system code
3. Fix the prompts to teach better patterns
4. Fix tools to provide better feedback
5. Add evals for different project types to catch overfitting
