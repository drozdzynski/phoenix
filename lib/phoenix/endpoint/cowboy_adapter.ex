defmodule Phoenix.Endpoint.CowboyAdapter do
  @moduledoc """
  The Cowboy adapter for Phoenix.

  It implements the required `child_spec/3` function as well
  as the handler for the WebSocket transport.

  ## Custom dispatch options

  *NOTE*: This feature depends on the internals of Cowboy 1.0 API
  and how it integrates with Phoenix. Those may change at *any time*,
  without backwards compatibility.

  You can provide custom dispatch options in order to use Phoenix's
  builtin Cowboy server with custom handlers. For example, to handle
  raw WebSockets [as shown in Cowboy's docs](https://github.com/ninenines/cowboy/tree/1.0.x/examples)).

  The options are passed to both `:http` and `:https` keys in the
  endpoint configuration. However, once you pass your custom dispatch
  options, you will need to manually wire all Phoenix endpoints,
  including the socket transports.

  You will need the following rules:

    * Per websocket transport:

      ```
      {"/socket/websocket", Phoenix.Endpoint.CowboyWebSocket,
        {Phoenix.Transports.WebSocket,
          {MyAppWeb.Endpoint, MyAppWeb.UserSocket, :websocket}}}
      ```

    * Per longpoll transport:

      ```
      {"/socket/long_poll", Plug.Adapters.Cowboy.Handler,
        {Phoenix.Transports.LongPoll,
          {MyAppWeb.Endpoint, MyAppWeb.UserSocket, :longpoll}}}
      ```

    * For the live-reload websocket:

      ```
      {"/phoenix/live_reload/socket/websocket", Phoenix.Endpoint.CowboyWebSocket,
        {Phoenix.Transports.WebSocket,
          {MyAppWeb.Endpoint, Phoenix.LiveReloader.Socket, :websocket}}}
      ```

      If you decide to include the live-reload websocket, you should
      disable it when building for production.

    * For the endpoint:

      ```
      {:_, Plug.Adapters.Cowboy.Handler, {MyAppWeb.Endpoint, []}}
      ```

  For example:

      config :myapp, MyAppWeb.Endpoint,
        http: [dispatch: [
                {:_, [
                    {"/foo", MyAppWeb.CustomHandler, []},
                    {"/bar", MyAppWeb.AnotherHandler, []},
                    {"/phoenix/live_reload/socket/websocket", Phoenix.Endpoint.CowboyWebSocket,
                      {Phoenix.Transports.WebSocket,
                        {MyAppWeb.Endpoint, Phoenix.LiveReloader.Socket, :websocket}}},
                    {:_, Plug.Adapters.Cowboy.Handler, {MyAppWeb.Endpoint, []}}
                  ]}]]

  Note: if you reconfigure HTTP options in `MyAppWeb.Endpoint.init/1`,
  your dispatch options set in mix config will be overwritten.

  It is also important to specify your handlers first, otherwise
  Phoenix will intercept the requests before they get to your handler.
  """

  require Logger

  @doc false
  def child_spec(scheme, endpoint, config) do
    if scheme == :https do
      Application.ensure_all_started(:ssl)
    end

    # TODO: GET RID OF THIS.
    dispatches =
      for {path, socket} <- endpoint.__sockets__,
          {transport, {module, config}} <- socket.__transports__,
          # Allow handlers to be configured at the transport level
          handler = config[:cowboy] || default_for(module),
          do: {Path.join(path, Atom.to_string(transport)),
               handler,
               {module, {endpoint, socket, config}}}

    dispatches =
      dispatches ++ [{:_, Plug.Adapters.Cowboy.Handler, {endpoint, []}}]

    # Use put_new to allow custom dispatches
    config = Keyword.put_new(config, :dispatch, [{:_, dispatches}])

    {ref, mfa, type, timeout, kind, modules} =
      Plug.Adapters.Cowboy.child_spec(scheme, endpoint, [], config)

    # Rewrite MFA for proper error reporting
    mfa = {__MODULE__, :start_link, [scheme, endpoint, mfa]}
    {ref, mfa, type, timeout, kind, modules}
  end

  defp default_for(Phoenix.Transports.LongPoll), do: Plug.Adapters.Cowboy.Handler
  defp default_for(Phoenix.Transports.WebSocket), do: Phoenix.Endpoint.CowboyWebSocket
  defp default_for(_), do: nil

  @doc false
  def start_link(scheme, endpoint, {m, f, [ref | _] = a}) do
    # ref is used by Ranch to identify its listeners, defaulting
    # to plug.HTTP and plug.HTTPS and overridable by users.
    case apply(m, f, a) do
      {:ok, pid} ->
        Logger.info info(scheme, endpoint, ref)
        {:ok, pid}

      {:error, {:shutdown, {_, _, {{_, {:error, :eaddrinuse}}, _}}}} = error ->
        Logger.error [info(scheme, endpoint, ref), " failed, port already in use"]
        error

      {:error, _} = error ->
        error
    end
  end

  defp info(scheme, endpoint, ref) do
    {addr, port} = :ranch.get_addr(ref)
    addr_str = :inet.ntoa(addr)
    "Running #{inspect endpoint} with Cowboy using #{scheme}://#{addr_str}:#{port}"
  end
end