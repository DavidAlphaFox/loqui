defmodule Loqui.CowboyProtocol do
  use Loqui.Opcodes
  alias Loqui.{Protocol, Messages, Worker}
  require Logger

  @default_ping_interval 30_000
  @supported_versions [1]

  defstruct socket_pid: nil,
            transport: nil,
            env: nil,
            req: nil,
            handler: nil,
            handler_opts: nil,
            ping_interval: nil,
            supported_encodings: nil,
            supported_compressions: nil,
            worker_pool: nil,
            version: nil,
            encoding: nil,
            compression: nil,
            ping_timeout_ref: nil

  def upgrade(req, env, handler, handler_opts) do
    ref = env[:listener]
    :ranch.remove_connection(ref)
    [socket_pid, transport] = :cowboy_req.get([:socket, :transport], req)

    state = %__MODULE__{
      socket_pid: socket_pid,
      transport: transport,
      req: req,
      env: env,
      handler: handler,
      handler_opts: handler_opts,
    }

    handler_init(state)
  end

  def handler_init(%{transport: transport, req: req, handler: handler, handler_opts: handler_opts, env: env}=state) do
    case handler.loqui_init(transport, req, handler_opts) do
      {:ok, req, opts} ->
        %{state | req: req}
          |> set_opts(opts)
          |> loqui_handshake
      {:shutdown, req} ->
        {:ok, req, Keyword.put(env, :result, :closed)}
    end
  end

  def loqui_handshake(%{req: req}=state) do
    :cowboy_req.upgrade_reply(101, [{"Upgrade", "loqui"}], req)
    receive do
      {:cowboy_req, :resp_sent} -> :ok
    after
      0 -> :ok
    end

    refresh_ping_timeout(state) |> handler_loop(<<>>)
  end

  def handler_loop(%{socket_pid: socket_pid, transport: transport, ping_timeout_ref: ping_timeout_ref}=state, so_far) do
    transport.setopts(socket_pid, [active: :once])
    receive do
      {:response, seq, response} ->
        response = encode(state, response)
        message = Messages.response(0, seq, response)
        flush_responses(state, [message])
        socket_data(state, so_far)
      {:tcp, ^socket_pid, data} ->
        socket_data(state, <<so_far :: binary, data :: binary>>)
      {:tcp_closed, ^socket_pid} -> close(state, :tcp_closed)
      {:tcp_error, ^socket_pid, reason} -> goaway(state, reason)
      :ping_timeout ->
        if Process.read_timer(ping_timeout_ref) == false do
          goaway(state, :ping_timeout)
        else
          handler_loop(state, so_far)
        end
      other ->
        Logger.info "[loqui] unknown message. message=#{inspect other}"
        handler_loop(state, so_far)
    end
  end

  defp flush_responses(state, responses) do
    receive do
      {:response, seq, response} ->
        response = encode(state, response)
        message = Messages.response(0, seq, response)
        flush_responses(state, [message|responses])
    after
      0 -> do_send(state, responses)
    end
  end

  defp socket_data(state, data) do
    case Protocol.handle_data(data) do
      {:ok, request, extra} ->
        case handle_request(request, state) do
          {:ok, state} -> socket_data(state, extra)
          {:shutdown, reason} -> close(state, reason)
        end
      {:continue, extra} -> handler_loop(state, extra)
      {:error, reason} -> goaway(state, reason)
    end
  end

  defp handle_request({:hello, _flags, version, encodings, compressions}, %{ping_interval: ping_interval, supported_encodings: supported_encodings, supported_compressions: supported_compressions}=state) do
    encoding = choose_encoding(supported_encodings, encodings)
    compression = choose_compression(supported_compressions, compressions)

    cond do
      !Enum.member?(@supported_versions, version) ->
        goaway(state, :unsupported_version)
        {:shutdown, :unsupported_version}
      is_nil(encoding) ->
        goaway(state, :no_common_encoding)
        {:shutdown, :no_common_encoding}
      true ->
        flags = 0
        settings_payload = "#{encoding}|#{compression}"
        do_send(state, Messages.hello_ack(flags, ping_interval, settings_payload))
        {:ok, %{state | version: version, encoding: encoding, compression: compression}}
    end
  end
  defp handle_request({:ping, _flags, seq}, state) do
    state = refresh_ping_timeout(state)
    do_send(state, Messages.pong(0, seq))
    {:ok, state}
  end
  defp handle_request({:request, _flags, seq, request}, state) do
    request = decode(state, request)
    handler_request(state, seq, request)
    {:ok, state}
  end
  defp handle_request({:push, _flags, request}, state) do
    request = decode(state, request)
    handler_push(state, request)
    {:ok, state}
  end
  defp handle_request(request, state) do
    Logger.info "unknown request. request=#{inspect request}"
    {:ok, state}
  end

  defp send_error(state, seq, :handler_error, reason), do: send_error(state, seq, 1, reason)
  defp send_error(state, seq, code, reason) do
    reason = encode(state, reason)
    do_send(state, Messages.error(0, code, seq, reason))
  end

  def goaway(state, :normal), do: goaway(state, 0, "Normal")
  def goaway(state, :invalid_op), do: goaway(state, 1, "InvalidOp")
  def goaway(state, :unsupported_version), do: goaway(state, 2, "UnsupportedVersion")
  def goaway(state, :no_common_encoding), do: goaway(state, 3, "NoCommonEncoding")
  def goaway(state, :invalid_encoding), do: goaway(state, 4, "InvalidEncoding")
  def goaway(state, :invalid_compression), do: goaway(state, 5, "InvalidCompression")
  def goaway(state, :ping_timeout), do: goaway(state, 6, "PingTimeout")
  def goaway(state, :internal_server_error), do: goaway(state, 7, "InternalServerError")
  def goaway(state, :not_enough_options), do: goaway(state, 8, "NotEnoughOptions")

  def goaway(state, code, reason) do
    do_send(state, Messages.goaway(0, code, reason))
    close(state, reason)
  end

  defp do_send(%{transport: transport, socket_pid: socket_pid}=state, msg) do
    transport.send(socket_pid, msg)
    state
  end

  defp handler_request(%{handler: handler, worker_pool: worker_pool}=state, seq, request) do
    :poolboy.transaction(worker_pool, fn pid ->
      on_complete = fn (response) ->
        response = encode(state, response)
        do_send(state, Messages.response(0, seq, response))
      end
      Worker.request(pid, {handler, :loqui_request, [request]}, seq, self)
    end)
  end
  defp handler_push(%{handler: handler, worker_pool: worker_pool}, request) do
    :poolboy.transaction(worker_pool, fn pid ->
      Worker.push(pid, {handler, :loqui_push, [request]})
    end)
  end
  defp handler_terminate(%{handler: handler, req: req}, reason) do
    handler.loqui_terminate(reason, req)
  end

  defp close(%{transport: transport, socket_pid: socket_pid, env: env, req: req}=state, reason) do
    handler_terminate(state, reason)
    transport.close(socket_pid)
    {:ok, req, Keyword.put(env, :result, :closed)}
  end

  defp set_opts(state, opts) do
    %{supported_encodings: supported_encodings, supported_compressions: supported_compressions, worker_pool: worker_pool} = opts
    ping_interval = Map.get(opts, :ping_interval, @default_ping_interval)
    %{state |
      ping_interval: ping_interval,
      supported_encodings: supported_encodings,
      supported_compressions: supported_compressions,
      worker_pool: worker_pool
    }
  end

  def encode(%{encoding: "erlpack"}, msg), do: :erlang.term_to_binary(msg)
  def decode(%{encoding: "erlpack"}, msg), do: :erlang.binary_to_term(msg)

  defp choose_encoding(_supported_encodings, []), do: nil
  defp choose_encoding(supported_encodings, [encoding | encodings]) do
    if Enum.member?(supported_encodings, encoding), do: encoding, else: choose_encoding(supported_encodings, encodings)
  end

  defp choose_compression(_supported_compressions, []), do: nil
  defp choose_compression(supported_compressions, [compression | compressions]) do
    if Enum.member?(supported_compressions, compression), do: compression, else: choose_compression(supported_compressions, compressions)
  end

  defp refresh_ping_timeout(%{ping_interval: ping_interval, ping_timeout_ref: prev_ref}=state) do
    if prev_ref do
      Process.cancel_timer(prev_ref)
    end
    ref = Process.send_after(self, :ping_timeout, ping_interval)
    %{state | ping_timeout_ref: ref}
  end
end
