defmodule BoomLooperWeb.ChannelCase do
  @moduledoc """
  Test case for channel tests.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      import Phoenix.ChannelTest
      @endpoint BoomLooperWeb.Endpoint
    end
  end
end
