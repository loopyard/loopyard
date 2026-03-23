# Set BOOMLOOPER_HOME to a local dir so tests don't write to ~/.boomlooper
boomlooper_home = Path.join(File.cwd!(), ".boomlooper_home")
File.mkdir_p!(boomlooper_home)
System.put_env("BOOMLOOPER_HOME", boomlooper_home)

ExUnit.start(exclude: [:docker])
