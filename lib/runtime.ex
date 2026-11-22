defmodule Gfs.Runtime do
  @enforce_keys [:now, :choose]
  defstruct [:now, :choose]

  @type t :: %__MODULE__{
    now: (() -> DateTime.t()),
    choose: (list() -> term()),
  }

  @spec production() :: t()
  def production do
    %__MODULE__{
      now: &DateTime.utc_now/0,
      choose: &Enum.random/1,
    }
  end

  @doc "Returns the current time from the configured clock"
  @spec now(t()) :: DateTime.t()
  def now(%__MODULE__{now: now}) do
    now.()
  end

  @doc "Selects one item using the configured strategy"
  @spec choose(t(), list()) :: term()
  def choose(%__MODULE__{choose: choose}, candidates)
      when is_list(candidates) and candidates != [] do
    choose.(candidates)
  end

end
