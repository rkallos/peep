defmodule Peep.Persistent do
  @moduledoc false
  defstruct [:name, :storage]

  @type name() :: atom()

  @typep storage_default() :: {:default, :ets.tid()}
  @typep storage_striped() :: {:striped, %{pos_integer() => :ets.tid()}}
  @typep storage_default_prehashed() :: {:default_prehashed, :ets.tid()}
  @typep storage_striped_prehashed() :: {:striped_prehashed, %{pos_integer() => :ets.tid()}}
  @typep storage() ::
           storage_default()
           | storage_striped()
           | storage_default_prehashed()
           | storage_striped_prehashed()

  @type t() :: %__MODULE__{name: name(), storage: storage()}

  @spec new(Peep.Options.t()) :: t()
  def new(%Peep.Options{} = options) do
    %Peep.Options{name: name, storage: storage_impl} = options

    storage =
      case storage_impl do
        :default ->
          {:default, Peep.Storage.ETS.new()}

        :striped ->
          {:striped, Peep.Storage.Striped.new()}

        :default_prehashed ->
          {:default_prehashed, Peep.Storage.ETSPreHashed.new()}

        :striped_prehashed ->
          {:striped_prehashed, Peep.Storage.StripedPreHashed.new()}
      end

    %__MODULE__{
      name: name,
      storage: storage
    }
  end

  @spec store(t()) :: :ok
  def store(%__MODULE__{} = term) do
    %__MODULE__{name: name} = term
    :persistent_term.put(key(name), term)
  end

  @spec fetch(name()) :: t() | nil
  def fetch(name) when is_atom(name) do
    :persistent_term.get(key(name), nil)
  end

  @spec erase(name()) :: :ok
  def erase(name) when is_atom(name) do
    :persistent_term.erase(name)
    :ok
  end

  @spec storage(name()) :: {module(), term()} | nil
  def storage(name) when is_atom(name) do
    case fetch(name) do
      %__MODULE__{storage: {:default, tid}} ->
        {Peep.Storage.ETS, tid}

      %__MODULE__{storage: {:striped, tids}} ->
        {Peep.Storage.Striped, tids}

      %__MODULE__{storage: {:default_prehashed, tid}} ->
        {Peep.Storage.ETSPreHashed, tid}

      %__MODULE__{storage: {:striped_prehashed, tids}} ->
        {Peep.Storage.StripedPreHashed, tids}

      _ ->
        nil
    end
  end

  defp key(name) when is_atom(name) do
    {Peep, name}
  end
end
