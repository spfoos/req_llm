defmodule ReqLLM.Application do
  @moduledoc false

  # Application supervisor for ReqLLM.

  # Starts and supervises the Finch instance used for all HTTP operations,
  # both streaming (via `Finch.stream/5`) and non-streaming (via Req).
  # Provides optimized connection pools with sensible defaults that can be
  # overridden via application configuration.

  # ## Configuration

  # - `:load_dotenv` - Whether to automatically load `.env` files from the current
  #   working directory at startup. Defaults to `true`. Set to `false` if you prefer
  #   to manage environment variables yourself or use a different `.env` loading strategy.

  #       config :req_llm, load_dotenv: false

  use Application

  @impl true
  def start(_type, _args) do
    req_llm_load_dotenv = Application.get_env(:req_llm, :load_dotenv, true)

    sync_llm_db_dotenv_config(req_llm_load_dotenv)

    if req_llm_load_dotenv do
      load_dotenv()
    end

    load_llm_db_catalog()
    initialize_registry()
    initialize_schema_cache()

    finch_config = get_finch_config()

    children =
      [
        {Finch, finch_config},
        {Task.Supervisor, name: ReqLLM.TaskSupervisor},
        ReqLLM.Providers.GoogleVertex.TokenCache
      ] ++ dev_children()

    opts = [strategy: :one_for_one, name: ReqLLM.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @doc """
  Gets the Finch configuration from application environment with unified pool defaults.

  ReqLLM normalizes all providers through a single connection pool, making it as easy
  as changing the model spec to switch providers.

  Users can override pool configurations by setting:

      config :req_llm,
        finch: [
          name: ReqLLM.Finch,
          pools: %{
            :default => [protocols: [:http2, :http1], size: 1, count: 16]
          }
        ]
  """
  @spec get_finch_config() :: keyword()
  def get_finch_config do
    user_config = Application.get_env(:req_llm, :finch, [])

    default_config = [
      name: ReqLLM.Finch,
      pools: get_default_pools()
    ]

    Keyword.merge(default_config, user_config)
  end

  @doc """
  Gets the default Finch name used by ReqLLM for all HTTP operations.
  """
  @spec finch_name() :: atom()
  def finch_name do
    Application.get_env(:req_llm, :finch, [])
    |> Keyword.get(:name, ReqLLM.Finch)
  end

  # Unified connection pool defaults supporting all providers
  # ReqLLM's core value is provider normalization - users should be able to
  # switch providers by just changing the model spec
  defp get_default_pools do
    %{
      # Single default pool that handles all providers efficiently
      # HTTP/1 only to avoid Finch issue #265 (HTTP/2 flow control bug with large bodies)
      # Once https://github.com/sneako/finch/issues/265 is fixed, we can use [:http2, :http1]
      :default => [
        protocols: [:http1],
        # Single persistent connection per pool
        size: 1,
        # 8 pools for good concurrency
        count: 8
      ]
    }
  end

  defp dev_children do
    case System.get_env("TIDEWAVE_REPL") do
      "true" ->
        ensure_tidewave_started()
        port = String.to_integer(System.get_env("TIDEWAVE_PORT", "10001"))
        [{Bandit, plug: Tidewave, port: port}]

      _ ->
        []
    end
  end

  defp ensure_tidewave_started do
    case Application.ensure_all_started(:tidewave) do
      {:ok, _} -> :ok
      {:error, _} -> :ok
    end
  end

  defp initialize_registry do
    ReqLLM.Providers.initialize()
  end

  defp initialize_schema_cache do
    :ets.new(:req_llm_schema_cache, [
      :set,
      :public,
      :named_table,
      read_concurrency: true
    ])
  end

  defp sync_llm_db_dotenv_config(req_llm_load_dotenv) do
    case Application.fetch_env(:llm_db, :load_dotenv) do
      :error ->
        Application.put_env(:llm_db, :load_dotenv, req_llm_load_dotenv)

      {:ok, _value} ->
        :ok
    end
  end

  # llm_db is an included_application of req_llm (see mix.exs). Load its catalog
  # into :persistent_term WITHOUT starting it as an OTP application.
  #
  # Application.ensure_all_started(:llm_db) would invoke LLMDB.Application.start/2
  # through the application controller, which then tracks that callback's return
  # value — {:ok, self()} — as llm_db's "top supervisor". But that value is a bare
  # process with no sys loop, so OTP hot code upgrades hang on it: during any relup
  # that updates a gen_server/supervisor, release_handler:get_supervised_procs/0
  # walks every *started* application and calls sys:get_status on each app's root.
  # llm_db's root never answers, so it times out after a hardcoded 5s and aborts
  # the whole install (see cmesh hot-upgrade incident, 2026-06-07).
  #
  # Calling start/2 directly runs the exact same bootstrap — its only real effect
  # is populating the persistent_term catalog (LLMDB.load/0) — but registers no
  # application master, so there is no unsupervised root for release_handler to
  # interrogate. As an included_application, llm_db is shipped + loaded with the
  # release; it just must not be *started*.
  defp load_llm_db_catalog do
    case LLMDB.Application.start(:normal, []) do
      {:ok, _} -> :ok
      {:error, reason} -> raise "failed to load :llm_db catalog: #{inspect(reason)}"
    end
  end

  defp load_dotenv do
    env_file = Path.join(File.cwd!(), ".env")

    if File.exists?(env_file) do
      case Dotenvy.source(env_file) do
        {:ok, env_map} ->
          Enum.each(env_map, fn {key, value} ->
            if System.get_env(key) == nil do
              System.put_env(key, value)
            end
          end)

        {:error, _reason} ->
          :ok
      end
    else
      :ok
    end
  end
end
