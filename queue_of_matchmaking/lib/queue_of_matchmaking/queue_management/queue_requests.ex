defmodule QueueOfMatchmaking.QueueRequests do
  @moduledoc """
  Functions for the Queue Requests
  """

  alias QueueOfMatchmaking.{
    QueuePolicy,
    QueueState
  }

  @type raw_request :: map()
  @type normalized_request :: %{
          required(:user_id) => String.t(),
          required(:rank) => non_neg_integer()
        }

  @spec enqueue(raw_request(), QueueState.t()) ::
          {:ok, map(), QueueState.t()}
          | {:error, term(), QueueState.t()}
          | {:error, term()}
  def enqueue(params, state) do
    with {:ok, request} <- normalize(params),
         {:ok, entry} <- build_entry(request, state),
         {:ok, state} <- QueuePolicy.before_enqueue(entry, state),
         {:ok, handle, state} <- QueueState.insert_entry(entry, state) do
      QueueState.fetch(handle, state)
    end
  end

  @spec normalize(raw_request()) :: {:ok, normalized_request()} | {:error, term()}
  def normalize(%{user_id: user_id, rank: rank}) do
    with {:ok, user_id} <- normalize_user_id(user_id),
         {:ok, rank} <- normalize_rank(rank) do
      {:ok, %{user_id: user_id, rank: rank}}
    end
  end

  def normalize(%{"userId" => user_id, "rank" => rank}) do
    normalize(%{user_id: user_id, rank: rank})
  end

  def normalize(_), do: {:error, :invalid_params}

  defp normalize_user_id(user_id) when is_binary(user_id) do
    trimmed = String.trim(user_id)

    cond do
      trimmed == "" -> {:error, :invalid_user_id}
      String.length(trimmed) > 255 -> {:error, :invalid_user_id}
      true -> {:ok, trimmed}
    end
  end

  defp normalize_user_id(_), do: {:error, :invalid_user_id}

  defp normalize_rank(rank) when is_integer(rank) and rank >= 0, do: {:ok, rank}
  defp normalize_rank(_), do: {:error, :invalid_rank}

  defp build_entry(%{user_id: user_id, rank: rank}, %QueueState{time_fn: time_fn}) do
    now = time_fn.(:millisecond)

    {:ok,
     %{
       user_id: user_id,
       rank: rank,
       inserted_at: now,
       meta: %{source: :enqueue},
       manager_now: now
     }}
  end
end
