defmodule Kadabra.Stream do
  @moduledoc """
  Struct returned from open connections.
  """
  defstruct [:id, :uri, :connection, :encoder, :decoder, :settings,
             :socket, headers: [], body: "", scheme: :https]

  alias Kadabra.{Connection, Encodable, Hpack, Http2, Stream}
  alias Kadabra.Frame.{Continuation, Data, Headers, PushPromise, RstStream}

  @data 0x0
  @headers 0x1

  @closed :closed
  @half_closed_local :half_closed_local
  @half_closed_remote :half_closed_remote
  @idle :idle
  @open :open
  # @reserved_local :reserved_local
  @reserved_remote :reserved_remote

  def new(%Connection{} = conn, stream_id) do
    %__MODULE__{
      id: stream_id,
      uri: conn.uri,
      connection: self(),
      socket: conn.socket,
      settings: conn.settings,
      encoder: conn.encoder_state,
      decoder: conn.decoder_state
    }
  end

  def start_link(stream) do
    :gen_statem.start_link(__MODULE__, stream, [])
  end

  def cast_recv(pid, frame) do
    :gen_statem.cast(pid, {:recv, frame})
  end

  def cast_send(pid, frame) do
    :gen_statem.cast(pid, {:send, frame})
  end

  # Enter Events

  def handle_event(:enter, _old, @half_closed_remote, stream) do
    bin = stream.id |> RstStream.new |> Encodable.to_bin
    :ssl.send(stream.socket, bin)

    :gen_statem.cast(self(), :close)
    {:keep_state, stream}
  end
  def handle_event(:enter, _old, @closed, stream) do
    send(stream.connection, {:finished, Stream.Response.new(stream)})
    {:stop, :normal}
  end
  def handle_event(:enter, _old, _new, stream), do: {:keep_state, stream}

  def handle_event(:cast, :close, _state, stream) do
    {:next_state, @closed, stream}
  end

  def handle_event(:cast, {:recv, %RstStream{}}, state, stream)
    when state in [@open, @half_closed_local, @half_closed_remote, @closed] do
    {:next_state, :closed, stream}
  end

  def handle_event(:cast, {:recv, %Continuation{header_block_fragment: fragment}}, state, stream)
    when state in [@idle] do

    {:ok, headers} = Hpack.decode(stream.decoder, fragment)
    stream = %Stream{stream | headers: stream.headers ++ headers}

    {:keep_state, stream}
  end

  def handle_event(:cast, {:recv, %PushPromise{header_block_fragment: fragment}}, state, stream)
    when state in [@idle] do

    {:ok, headers} = Hpack.decode(stream.decoder, fragment)
    stream = %Stream{stream | headers: stream.headers ++ headers}

    send(stream.connection, {:push_promise, Stream.Response.new(stream)})
    {:next_state, @reserved_remote, stream}
  end

  def handle_event(:cast, {:recv, %Headers{header_block_fragment: fragment} = frame}, _state, stream) do
    {:ok, headers} = Hpack.decode(stream.decoder, fragment)
    stream = %Stream{stream | headers: stream.headers ++ headers}

    if frame.end_stream do
      {:next_state, @half_closed_remote, stream}
    else
      {:keep_state, stream}
    end
  end

  def handle_event(:cast, {:recv, %Data{end_stream: end_stream?,
                                        data: data}}, _state, stream) do
    stream = %Stream{stream | body: stream.body <> data}

    #unless data == nil || byte_size(data) <= 0 do
      # IO.inspect(byte_size(data), label: "window update bytes")
      # window_update = Http2.build_frame(0x8, 0x0, 0x0, <<byte_size(data)::32>>)
      # :ssl.send(stream.socket, window_update)
      #end

    cond do
      end_stream? -> {:next_state, @half_closed_remote, stream}
      true -> {:keep_state, stream}
    end
  end

  def handle_event(:cast, {:send_headers, headers, payload}, _state, stream) do
    #IO.puts("Sending, Stream ID: #{stream.id}")
    headers = add_headers(headers, stream)
    {:ok, encoded} = Hpack.encode(stream.encoder, headers)
    headers_payload = :erlang.iolist_to_binary(encoded)
    h = Http2.build_frame(@headers, 0x4, stream.id, headers_payload)

    :ssl.send(stream.socket, h)

    if payload do
      {:ok, settings} = Kadabra.ConnectionSettings.fetch(stream.settings)
      chunks = chunk(settings.max_frame_size, payload)
      send_chunks(stream.socket, stream.id, chunks)
    end

    {:next_state, @open, stream}
  end

  defp send_chunks(_socket, _stream_id, []), do: :ok
  defp send_chunks(socket, stream_id, [chunk | []]) do
    h_p = Http2.build_frame(@data, 0x1, stream_id, chunk)
    :ssl.send(socket, h_p)
  end
  defp send_chunks(socket, stream_id, [chunk | rest]) do
    h_p = Http2.build_frame(@data, 0x0, stream_id, chunk)
    :ssl.send(socket, h_p)

    send_chunks(socket, stream_id, rest)
  end

  defp chunk(size, bin) when byte_size(bin) >= size do
    {chunk, rest} = :erlang.split_binary(bin, size)
    [chunk | chunk(size, rest)]
  end
  defp chunk(_size, <<>>), do: []
  defp chunk(_size, bin), do: [bin]

  defp add_headers(headers, stream) do
    h = headers ++
    [
      {":scheme", Atom.to_string(stream.scheme)},
      {":authority", List.to_string(stream.uri)}
    ]
    # sorting headers to have pseudo headers first.
    Enum.sort(h, fn({a, _b}, {c, _d}) -> a < c end)
  end

  def init(stream), do: {:ok, @idle, stream}

  def callback_mode, do: [:handle_event_function, :state_enter]

  def terminate(_reason, _state, _data), do: :void

  def code_change(_vsn, state, data, _extra), do: {:ok, state, data}
end
