defmodule Loopyard.Tools.ControlPlane.Gh do
  use Loopyard.Tool,
    name: "gh",
    description:
      "Run a GitHub CLI (`gh`) command using the operating identity's GitHub " <>
        "auth — this is your window into GitHub. Query orgs, repos, PRs, issues, " <>
        "or hit the API (`gh api ...`) to look things up before you propose " <>
        "creating a project. Pass just the arguments (no leading 'gh'), e.g. " <>
        "'org list' or 'repo list overtonxyz --limit 20'. Runs host-side against " <>
        "the workstation's gh; you never get a raw shell. Prefer read/query " <>
        "commands — you propose project changes through the create_* tools, not gh.",
    busy_words: ["checking GitHub"],
    params: [
      agent_id: {:string, required: true},
      args: {:string, required: true, description: "gh arguments, e.g. 'org list'"}
    ]

  alias Loopyard.Tools.CommandGuard

  def execute(%{args: args}, _assigns) do
    with :ok <- CommandGuard.gh(args || ""),
         argv when argv != [] <- OptionParser.split(args || "") do
      case System.cmd("gh", argv, stderr_to_stdout: true) do
        {out, 0} -> {:ok, blank_to_note(out)}
        {out, code} -> {:error, "gh exited #{code}:\n#{out}"}
      end
    else
      {:error, _} = err -> err
      [] -> {:error, "No gh command given."}
    end
  rescue
    e -> {:error, "gh failed: #{Exception.message(e)}"}
  catch
    _, reason -> {:error, "gh failed: #{inspect(reason)}"}
  end

  defp blank_to_note(out) do
    case String.trim(out) do
      "" -> "(no output)"
      _ -> out
    end
  end
end
