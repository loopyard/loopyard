defmodule LoopyardWeb.ActivitySoundTest do
  @moduledoc "The sound bridge's two pure decisions: how loud, and which bell."
  use ExUnit.Case, async: true

  alias LoopyardWeb.ActivitySound
  alias Loopyard.Events.Activity.Event
  alias Loopyard.Notifications.Item

  test "the level follows how many agents are thinking, floor to a full hum at three" do
    assert_in_delta ActivitySound.level_for(0), 0.12, 0.001
    assert ActivitySound.level_for(1) > ActivitySound.level_for(0)
    assert_in_delta ActivitySound.level_for(3), 0.7, 0.001
    assert ActivitySound.level_for(9) == ActivitySound.level_for(3), "more doesn't get louder"
  end

  test "three moments, three voices; everything else is silent" do
    assert ActivitySound.chime_for(%Event{
             kind: :turn_end,
             workspace_id: "ws",
             summary: "Done it."
           }) == "done"

    assert ActivitySound.chime_for(%Event{kind: :turn_end, workspace_id: "ws", summary: ""}) ==
             nil

    assert ActivitySound.chime_for(%Event{kind: :turn_end, workspace_id: nil, summary: "x"}) ==
             nil

    assert ActivitySound.chime_for(%Item{kind: :question}) == "attention"
    assert ActivitySound.chime_for(%Item{kind: :approval}) == "attention"
    assert ActivitySound.chime_for(%Item{kind: :secret}) == "attention"
    assert ActivitySound.chime_for(%Item{kind: :finished}) == nil
    assert ActivitySound.chime_for(%Event{kind: :status, summary: "crashed"}) == "alert"
    assert ActivitySound.chime_for(%Event{kind: :status, summary: "thinking"}) == nil
    assert ActivitySound.chime_for(%Event{kind: :status, summary: "idle"}) == nil
  end
end
