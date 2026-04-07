# Set BOOMLOOPER_HOME to a local dir so tests don't write to ~/.boomlooper
boomlooper_home = Path.join(File.cwd!(), ".boomlooper_home")

# Clean up stale projects.json from previous test runs
projects_json = Path.join(boomlooper_home, "projects.json")
File.rm(projects_json)

File.mkdir_p!(boomlooper_home)
System.put_env("BOOMLOOPER_HOME", boomlooper_home)

ExUnit.start(exclude: [:docker])
