defmodule Gfs.TestRuntime do
  def start_link(_opts) do
    {:ok, clock} = Agent.start_link(fn -> ~U[2026-01-01 00:00:00.000000Z] end)
    {:ok, rng} = Agent.start_link(fn -> :rand.seed(:exsss, {42, 42, 42}) end)

    runtime = %Gfs.Runtime{
      now: fn -> Agent.get(clock, & &1) end,
      choose: fn candidates ->
        Agent.get_and_update(rng, fn state ->
          {i, new_state} = :rand.uniform_s(length(candidates), state)
          {Enum.at(candidates, i - 1), new_state}
        end)
      end
    }

    {:ok, %{runtime: runtime, clock: clock}}
  end

  def advance(%{clock: clock}, secs), do: Agent.update(clock, &DateTime.add(&1, secs, :second))
  def now(%{clock: clock}), do: Agent.get(clock, & &1)
end
