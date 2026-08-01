# Finish it — the outstanding list, with the .loopyard portability bug at the top

Everything still open from this session's punch list, plus the two questions
Brad raised about `.loopyard`. Ordered by what blocks the most.

---

## P0-1. `.loopyard` is not portable between branches

### The two questions, answered

**"Why are there hardcoded volumes in the .loopyard file?"**

Because *we* put them there. `Tools.Container.WriteFile.execute/2` intercepts any
write ending in `docker-compose.yml` and substitutes before the bytes ever reach
disk:

```elixir
content
|> String.replace("${CODE_VOLUME}", volume_name)
|> String.replace("${WORKSPACE_ID}", workspace_id)
```

The agent authors the portable thing the setup guide tells it to
(`${CODE_VOLUME}`); Loopyard bakes in `loopyard-<this-workspace>-code` and writes
*that*. Verified on the live gbrain volume — line 88 of the committed file reads
`name: loopyard-261219b7-code`, and the header comment names the same id.

The substitution is also **redundant**: `Compose.process_agent_compose/3` already
resolves `${CODE_VOLUME}` at run time (`update_volumes_placeholder/2`), which is
the correct seam. Doing it at write time buys nothing and costs portability.

**"Why did this project not find the .loopyard folder and use it?"**

It found it. It couldn't trust it. The committed file named *another workspace's*
volume (`edb28f7c`, from the session that authored it), so to an agent reading it
on branch `261219b7` it looked like foreign, stale infrastructure rather than
this workspace's config — and it got rewritten instead of reused.

`Compose.normalize_code_volume_names/2` already rewrites a foreign
`loopyard-*-code` name at process time, so the cluster *runs* correctly. That is
precisely what made this hard to see: the system works while the file on disk
lies. The fix has to be at the file, not only at the seam that reads it.

There is a second, smaller confusion underneath: `CLAUDE.md` says
`.loopyard/workspace/` is **gitignored**, but gbrain has it **tracked**
(`git ls-files` shows both `Dockerfile` and `docker-compose.yml`). Tracking it is
the more useful choice — that's how a new branch inherits a working dev
environment — but it is only *safe* once the file carries no workspace-specific
names.

### The work

1. **Stop substituting at write time.** Remove the `${CODE_VOLUME}` /
   `${WORKSPACE_ID}` replacement from `WriteFile`. The file on disk stays
   portable; `process_agent_compose/3` resolves at run time, as designed.
2. **Normalize on write, don't just tolerate on read.** If an agent hardcodes a
   literal `loopyard-<id>-code` anyway, rewrite it back to `${CODE_VOLUME}`
   before writing, and say so in the tool result so the agent learns.
3. **Migrate what's already on disk.** Existing committed composes carry a baked
   name; de-bake it on read-modify-write so branches self-heal.
4. **Settle the tracked-vs-ignored question** in `CLAUDE.md` and the setup guide:
   `.loopyard/workspace/` is TRACKED and must be workspace-agnostic.
5. **Tests**: a compose written with `${CODE_VOLUME}` round-trips unchanged; a
   compose written with a literal comes back as `${CODE_VOLUME}`; the processed
   output still resolves to this workspace's volume.

---

## P0-2. Test isolation — the suite reaches the developer's live Docker

Half fixed. `Workstation.resource_prefix/0` now namespaces the identity
container + home volume, and `materialize_home/2` raises outside its prefix, so
the token wipe is dead. But the raising guard I trialled in `Docker.docker/2`
lit up **128 tests** — the suite touches real resources well beyond identity:
`loopyard-<ws>-code`, `-cache`, `-work`, `-canonical`.

The work: extend the prefix through `VolumeManager`, `WorkContainer` and
`CanonicalRepo`, then re-enable the guard so naming a real resource fails loudly.
Until that lands, a run can silently mutate live state, and the suite's
1817–1820 flakiness makes any verification a coin flip.

---

## P1-3. Changes / History show the Files panel

All three route to `detail_kind == :volume`, so the same volume detail renders
for each. Changes should summarise the working tree; History the recent commits.

## P1-4. Integration pages

`/workstations/:id/claude` and the pattern for GitHub / Fly. Status most
dominant, then how to connect; "Other ways" become sub-pages; drop the trailing
Reference block. One pattern all integrations follow.

## P1-5. A turn wedged on auth never resets

An agent stuck mid-turn doesn't recover when a credential lands:
`reload_agents` → `restart_session(:credentials)` skips a "busy" agent, but busy
is a lie when the turn died on auth. Needs to distinguish a turn that can't
progress from one that's working. (The token-wipe fix removes the *cause* that
kept firing it; this is the stuck-state cleanup.)

## P2-6. Operator rail

Composes its own `PAST HOUR` / `TODAY` rows instead of
`ProjectList.project_groups`, and ~14 elements sit under 44px on mobile.

## P2-7. Reviewer scroll/snap

Replace prev/next arrows with a scroll-snap deck (`scroll-snap-type: y
proximity`, `scroll-snap-align: start`). State restructure: ReviewLive renders
one slide with subscriptions keyed to it.

---

## Deliberate exceptions (not bugs)

- The question card's Skip/Chat stay at 40px, under the 44px floor: they're
  sized down relative to Answer so discarding a question isn't a plausible
  mis-tap. Expanding their hit area would undo that on purpose.
