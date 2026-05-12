defmodule LoopyardWeb.ChannelCase do
  @moduledoc """
  Test case for channel tests.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      import Phoenix.ChannelTest
      @endpoint LoopyardWeb.Endpoint
    end
  end
end
