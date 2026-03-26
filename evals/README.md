# Evals

Test BoomLooper's setup agent against real projects.

## Structure

```
evals/
├── <project>/
│   ├── project.md           # stack, gotchas, what success looks like
│   └── runs/
│       └── <timestamp>.md   # one file per eval run
└── README.md
```

## Running

Use the `/eval` skill or from IEx:

```elixir
BoomLooper.EvalRunner.run("/path/to/project", clean: true)
```

## Adding a project

Create `evals/<name>/project.md` with frontmatter, then run the eval.
