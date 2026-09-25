-module(raw_client).

-export([request/7]).

request(Port, Method, Path, Headers, Body, ChunkSize, Timeout) ->
    case gen_tcp:connect("127.0.0.1", Port, [binary, {active, false}], Timeout) of
        {ok, Socket} ->
            try
                RequestHead = [Method, <<" ">>, Path, <<" HTTP/1.1\r\n">>,
                               [[K, <<": ">>, V, <<"\r\n">>] || {K, V} <- Headers],
                               <<"Transfer-Encoding: chunked\r\n\r\n">>],
                case gen_tcp:send(Socket, RequestHead) of
                    ok ->
                        %% A server may reject a request before consuming its body.
                        case send_chunks(Socket, Body, ChunkSize) of
                            ok -> receive_response(Socket, Timeout);
                            {error, closed} -> receive_response(Socket, Timeout);
                            {error, econnreset} -> receive_response(Socket, Timeout);
                            Error -> Error
                        end;
                    Error -> Error
                end
            after
                gen_tcp:close(Socket)
            end;
        Error -> Error
    end.

send_chunks(Socket, <<>>, _ChunkSize) ->
    gen_tcp:send(Socket, <<"0\r\n\r\n">>);
send_chunks(Socket, Body, ChunkSize) when ChunkSize > 0 ->
    Size = min(byte_size(Body), ChunkSize),
    <<Chunk:Size/binary, Rest/binary>> = Body,
    case gen_tcp:send(Socket, [integer_to_binary(Size, 16), <<"\r\n">>,
                               Chunk, <<"\r\n">>]) of
        ok -> send_chunks(Socket, Rest, ChunkSize);
        Error -> Error
    end.

receive_response(Socket, Timeout) ->
    case read_until(Socket, <<>>, <<"\r\n\r\n">>, Timeout) of
        {ok, Head, Rest} ->
            case parse_head(Head) of
                {ok, Status, Headers} ->
                    case read_body(Socket, Rest, Headers, Timeout) of
                        {ok, Body} -> {ok, {Status, Headers, Body}};
                        Error -> Error
                    end;
                Error -> Error
            end;
        Error -> Error
    end.

read_until(Socket, Buffer, Marker, Timeout) ->
    case binary:match(Buffer, Marker) of
        {At, Length} ->
            <<Before:At/binary, _:Length/binary, Rest/binary>> = Buffer,
            {ok, Before, Rest};
        nomatch ->
            case gen_tcp:recv(Socket, 0, Timeout) of
                {ok, Data} -> read_until(Socket, <<Buffer/binary, Data/binary>>, Marker, Timeout);
                Error -> Error
            end
    end.

parse_head(Head) ->
    case binary:split(Head, <<"\r\n">>, [global]) of
        [StatusLine | HeaderLines] ->
            case binary:split(StatusLine, <<" ">>, [global]) of
                [<<"HTTP/1.1">>, Code | _] -> parse_headers(Code, HeaderLines);
                [<<"HTTP/1.0">>, Code | _] -> parse_headers(Code, HeaderLines);
                _ -> {error, malformed_response}
            end;
        _ -> {error, malformed_response}
    end.

parse_headers(Code, Lines) ->
    try
        Status = binary_to_integer(Code),
        Headers = [parse_header(Line) || Line <- Lines],
        {ok, Status, Headers}
    catch
        error:_ -> {error, malformed_response}
    end.

parse_header(Line) ->
    case binary:match(Line, <<":">>) of
        {At, 1} ->
            <<Name:At/binary, _:1/binary, Value/binary>> = Line,
            {string:lowercase(Name), string:trim(Value)};
        nomatch -> erlang:error(malformed_response)
    end.

read_body(Socket, Rest, Headers, Timeout) ->
    case lists:keyfind(<<"transfer-encoding">>, 1, Headers) of
        {_, Encoding} ->
            case binary:match(string:lowercase(Encoding), <<"chunked">>) of
                nomatch -> read_nonchunked(Socket, Rest, Headers, Timeout);
                _ -> read_chunks(Socket, Rest, Timeout, [])
            end;
        false -> read_nonchunked(Socket, Rest, Headers, Timeout)
    end.

read_nonchunked(Socket, Rest, Headers, Timeout) ->
    case lists:keyfind(<<"content-length">>, 1, Headers) of
        {_, Length} ->
            try read_exact(Socket, Rest, binary_to_integer(Length), Timeout)
            catch error:_ -> {error, malformed_response}
            end;
        false -> read_to_close(Socket, Rest, Timeout)
    end.

read_exact(_Socket, Buffer, Count, _Timeout) when byte_size(Buffer) >= Count, Count >= 0 ->
    <<Body:Count/binary, _/binary>> = Buffer,
    {ok, Body};
read_exact(Socket, Buffer, Count, Timeout) when Count >= 0 ->
    case gen_tcp:recv(Socket, 0, Timeout) of
        {ok, Data} -> read_exact(Socket, <<Buffer/binary, Data/binary>>, Count, Timeout);
        Error -> Error
    end;
read_exact(_, _, _, _) -> {error, malformed_response}.

read_to_close(Socket, Buffer, Timeout) ->
    case gen_tcp:recv(Socket, 0, Timeout) of
        {ok, Data} -> read_to_close(Socket, <<Buffer/binary, Data/binary>>, Timeout);
        {error, closed} -> {ok, Buffer};
        Error -> Error
    end.

read_chunks(Socket, Buffer, Timeout, Parts) ->
    case read_until(Socket, Buffer, <<"\r\n">>, Timeout) of
        {ok, SizeLine, Rest} ->
            try
                [Hex | _] = binary:split(SizeLine, <<";">>),
                Size = binary_to_integer(Hex, 16),
                case Size of
                    0 -> read_trailers(Socket, Rest, Timeout, Parts);
                    _ ->
                        case ensure_bytes(Socket, Rest, Size + 2, Timeout) of
                            {ok, <<Chunk:Size/binary, "\r\n", Tail/binary>>} ->
                                read_chunks(Socket, Tail, Timeout, [Chunk | Parts]);
                            {ok, _} -> {error, malformed_response};
                            Error -> Error
                        end
                end
            catch
                error:_ -> {error, malformed_response}
            end;
        Error -> Error
    end.

read_trailers(Socket, Buffer, Timeout, Parts) ->
    case read_until(Socket, Buffer, <<"\r\n">>, Timeout) of
        {ok, <<>>, _} -> {ok, iolist_to_binary(lists:reverse(Parts))};
        {ok, _, Rest} -> read_trailers(Socket, Rest, Timeout, Parts);
        Error -> Error
    end.

ensure_bytes(_Socket, Buffer, Count, _Timeout) when byte_size(Buffer) >= Count ->
    {ok, Buffer};
ensure_bytes(Socket, Buffer, Count, Timeout) ->
    case gen_tcp:recv(Socket, 0, Timeout) of
        {ok, Data} -> ensure_bytes(Socket, <<Buffer/binary, Data/binary>>, Count, Timeout);
        Error -> Error
    end.
