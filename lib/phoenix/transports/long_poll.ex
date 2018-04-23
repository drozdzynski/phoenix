defmodule Phoenix.Transports.LongPoll do
  @moduledoc false

  _ = """
  Socket transport for long poll clients.

  ## Configuration

  The long poll is configurable in your socket:

      transport :longpoll, Phoenix.Transports.LongPoll,
        window_ms: 10_000,
        pubsub_timeout_ms: 2_000,
        transport_log: false,
        crypto: [max_age: 1_209_600]

    * `:window_ms` - how long the client can wait for new messages
      in its poll request

    * `:pubsub_timeout_ms` - how long a request can wait for the
      pubsub layer to respond

    * `:crypto` - options for verifying and signing the token, accepted
      by `Phoenix.Token`. By default tokens are valid for 2 weeks

    * `:transport_log` - if the transport layer itself should log and, if so, the level

    * `:check_origin` - if we should check the origin of requests when the
      origin header is present. It defaults to true and, in such cases,
      it will check against the host value in `YourApp.Endpoint.config(:url)[:host]`.
      It may be set to `false` (not recommended) or to a list of explicitly
      allowed origins

    * `:code_reloader` - optionally override the default `:code_reloader` value
      from the socket's endpoint
  """

  @behaviour Plug

  import Plug.Conn
  alias Phoenix.Socket.Transport

  def default_config() do
    [window_ms: 10_000,
     pubsub_timeout_ms: 2_000,
     serializer: [{Phoenix.Socket.V1.JSONSerializer, "~> 1.0.0"},
                  {Phoenix.Socket.V2.JSONSerializer, "~> 2.0.0"}],
     transport_log: false,
     crypto: [max_age: 1_209_600]]
  end

  @doc false
  def init(opts), do: opts

  @doc false
  def call(conn, {endpoint, handler, transport, opts}) do
    conn
    |> fetch_query_params()
    |> put_resp_header("access-control-allow-origin", "*")
    |> Transport.code_reload(endpoint, opts)
    |> Transport.transport_log(opts[:transport_log])
    |> Transport.force_ssl(handler, endpoint, opts)
    |> Transport.check_origin(handler, endpoint, opts, &status_json/1)
    |> dispatch(endpoint, handler, transport, opts)
  end

  defp dispatch(%{halted: true} = conn, _, _, _, _) do
    conn
  end

  # Responds to pre-flight CORS requests with Allow-Origin-* headers.
  # We allow cross-origin requests as we always validate the Origin header.
  defp dispatch(%{method: "OPTIONS"} = conn, _, _, _, _) do
    headers = get_req_header(conn, "access-control-request-headers") |> Enum.join(", ")

    conn
    |> put_resp_header("access-control-allow-headers", headers)
    |> put_resp_header("access-control-allow-methods", "get, post, options")
    |> put_resp_header("access-control-max-age", "3600")
    |> send_resp(:ok, "")
  end

  # Starts a new session or listen to a message if one already exists.
  defp dispatch(%{method: "GET"} = conn, endpoint, handler, transport, opts) do
    case resume_session(conn.params, endpoint, opts) do
      {:ok, server_ref} ->
        listen(conn, server_ref, endpoint, opts)
      :error ->
        new_session(conn, endpoint, handler, transport, opts)
    end
  end

  # Publish the message encoded as a JSON body.
  defp dispatch(%{method: "POST"} = conn, endpoint, _, _, opts) do
    case resume_session(conn.params, endpoint, opts) do
      {:ok, server_ref} ->
        publish(conn, server_ref, endpoint, opts)
      :error ->
        conn |> put_status(:gone) |> status_json()
    end
  end

  # All other requests should fail.
  defp dispatch(conn, _, _, _, _) do
    send_resp(conn, :bad_request, "")
  end

  defp publish(conn, server_ref, endpoint, opts) do
    case read_body(conn, []) do
      {:ok, body, conn} ->
        status = transport_dispatch(endpoint, server_ref, body, opts)
        conn |> put_status(status) |> status_json()

      _ ->
        raise Plug.BadRequestError
    end
  end

  defp transport_dispatch(endpoint, server_ref, body, opts) do
    ref = make_ref()
    broadcast_from!(endpoint, server_ref, {:dispatch, client_ref(server_ref), body, ref})

    receive do
      {:ok, ^ref} -> :ok
      {:error, ^ref} -> :unauthorized
    after
      opts[:window_ms] -> :request_timeout
    end
  end

  ## Session handling

  defp new_session(conn, endpoint, handler, transport, opts) do
    serializer = opts[:serializer]

    priv_topic =
      "phx:lp:"
      <> Base.encode64(:crypto.strong_rand_bytes(16))
      <> (System.system_time(:milliseconds) |> Integer.to_string)

    args = [endpoint, handler, transport, __MODULE__, serializer,
            conn.params, opts[:window_ms], priv_topic]

    supervisor = Module.concat(endpoint, "LongPoll.Supervisor")

    case Supervisor.start_child(supervisor, args) do
      {:ok, :undefined} ->
        conn |> put_status(:forbidden) |> status_json()
      {:ok, server_pid} ->
        data  = {:v1, endpoint.config(:endpoint_id), server_pid, priv_topic}
        token = sign_token(endpoint, data, opts)
        conn |> put_status(:gone) |> status_token_messages_json(token, [])
    end
  end

  defp listen(conn, server_ref, endpoint, opts) do
    ref = make_ref()
    broadcast_from!(endpoint, server_ref, {:flush, client_ref(server_ref), ref})

    {status, messages} =
      receive do
        {:messages, messages, ^ref} ->
          {:ok, messages}

        {:now_available, ^ref} ->
          broadcast_from!(endpoint, server_ref, {:flush, client_ref(server_ref), ref})
          receive do
            {:messages, messages, ^ref} -> {:ok, messages}
          after
            opts[:window_ms]  -> {:no_content, []}
          end
      after
        opts[:window_ms] ->
          {:no_content, []}
      end

    conn
    |> put_status(status)
    |> status_token_messages_json(conn.params["token"], messages)
  end

  # Retrieves the serialized `Phoenix.LongPoll.Server` pid
  # by publishing a message in the encrypted private topic.
  defp resume_session(%{"token" => token}, endpoint, opts) do
    case verify_token(endpoint, token, opts) do
      {:ok, {:v1, id, pid, priv_topic}} ->
        server_ref = server_ref(endpoint.config(:endpoint_id), id, pid, priv_topic)

        ref = make_ref()
        :ok = subscribe(endpoint, server_ref)
        broadcast_from!(endpoint, server_ref, {:subscribe, client_ref(server_ref), ref})

        receive do
          {:subscribe, ^ref} -> {:ok, server_ref}
        after
          opts[:pubsub_timeout_ms]  -> :error
        end

      _ ->
        :error
    end
  end

  defp resume_session(_params, _endpoint, _opts), do: :error

  ## Helpers

  defp server_ref(endpoint_id, id, pid, topic) do
    if endpoint_id == id and Process.alive?(pid), do: pid, else: topic
  end

  defp client_ref(topic) when is_binary(topic), do: topic
  defp client_ref(pid) when is_pid(pid), do: self()

  defp subscribe(endpoint, topic) when is_binary(topic),
    do: Phoenix.PubSub.subscribe(endpoint.__pubsub_server__, topic, link: true)
  defp subscribe(_endpoint, pid) when is_pid(pid),
    do: :ok

  defp broadcast_from!(endpoint, topic, msg) when is_binary(topic),
    do: Phoenix.PubSub.broadcast_from!(endpoint.__pubsub_server__, self(), topic, msg)
  defp broadcast_from!(_endpoint, pid, msg) when is_pid(pid),
    do: send(pid, msg)

  defp sign_token(endpoint, data, opts) do
    Phoenix.Token.sign(endpoint, Atom.to_string(endpoint.__pubsub_server__), data, opts[:crypto])
  end

  defp verify_token(endpoint, signed, opts) do
    Phoenix.Token.verify(endpoint, Atom.to_string(endpoint.__pubsub_server__), signed, opts[:crypto])
  end

  defp status_json(conn) do
    status = conn.status || 200
    send_json(conn, "{\"status\":#{status}}")
  end

  defp status_token_messages_json(conn, token, messages) do
    status = conn.status || 200
    messages = [?[, Enum.intersperse(messages, ?,), ?]]
    token = Phoenix.json_library().encode_to_iodata!(token)
    send_json(conn, "{\"status\":#{status},\"token\":#{token},\"messages\":#{messages}}")
  end

  defp send_json(conn, json) do
    conn
    |> put_resp_header("content-type", "application/json; charset=utf-8")
    |> send_resp(200, json)
  end
end
