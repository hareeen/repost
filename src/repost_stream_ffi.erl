%% Streaming HTTP/1.1 PUT client built on hackney's `stream`-body mode.
%%
%% Flow: start (opens connection + sends headers) → send_chunk* → finish
%% (sends terminator + reads response) → close.

-module(repost_stream_ffi).

-export([start/7, send_chunk/2, finish/2, close/1, request_body/8]).

start(Scheme, Host, Port, Method, Path, Headers, Timeout) ->
    Url = build_url(Scheme, Host, Port, Path),
    case hackney:request(method_atom(Method), Url, Headers, stream, opts(Timeout)) of
        {ok, Ref} -> {ok, Ref};
        Err -> Err
    end.

send_chunk(_Ref, <<>>) -> {ok, nil};
send_chunk(Ref, Data) when is_binary(Data) ->
    case hackney:send_body(Ref, Data) of
        ok -> {ok, nil};
        Err -> Err
    end.

%% Closes the chunked body, reads status + headers, drains the response body.
%% If `finish_send_body` reports a closed connection (the server may have
%% rejected and hung up mid-write), we still try to read the response — the
%% server typically sent a 4xx XML error before closing.
finish(Ref, Timeout) ->
    _ = hackney:finish_send_body(Ref),
    case hackney:start_response(Ref) of
        {ok, Status, Headers, ConnPid} ->
            HeadersOut = [{string:lowercase(K), V} || {K, V} <- Headers],
            case hackney_conn:body(ConnPid, Timeout) of
                {ok, Body} -> {ok, {Status, HeadersOut, Body}};
                Err -> Err
            end;
        Err -> Err
    end.

close(Ref) ->
    hackney:close(Ref),
    nil.

request_body(Scheme, Host, Port, Method, Path, Headers, Body, Timeout) ->
    Url = build_url(Scheme, Host, Port, Path),
    case hackney:request(method_atom(Method), Url, Headers, Body, opts(Timeout)) of
        {ok, Status, RespHeaders, RespBody} when is_binary(RespBody) ->
            {ok, {Status, lower_headers(RespHeaders), RespBody}};
        {ok, Status, RespHeaders} ->
            {ok, {Status, lower_headers(RespHeaders), <<>>}};
        {ok, Status, RespHeaders, Ref} ->
            case hackney:body(Ref) of
                {ok, RespBody} -> {ok, {Status, lower_headers(RespHeaders), RespBody}};
                Err -> Err
            end;
        Err ->
            Err
    end.

%% --- internals --------------------------------------------------------

method_atom(<<"GET">>) -> get;
method_atom(<<"POST">>) -> post;
method_atom(<<"PUT">>) -> put;
method_atom(<<"DELETE">>) -> delete;
method_atom(<<"HEAD">>) -> head;
method_atom(<<"OPTIONS">>) -> options;
method_atom(<<"PATCH">>) -> patch;
method_atom(M) -> M.

build_url(Scheme, Host, Port, Path) ->
    SchemeBin = case Scheme of
        http -> <<"http">>;
        https -> <<"https">>
    end,
    PortPart = case {Scheme, Port} of
        {http, 80} -> <<>>;
        {https, 443} -> <<>>;
        {_, P} -> [<<":">>, integer_to_binary(P)]
    end,
    iolist_to_binary([SchemeBin, <<"://">>, Host, PortPart, Path]).

opts(Timeout) ->
    [
        {connect_timeout, Timeout},
        {recv_timeout, Timeout},
        {ssl_options,
            [{verify, verify_peer},
             {cacerts, public_key:cacerts_get()},
             {customize_hostname_check,
              [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}]}
    ].

lower_headers(Headers) ->
    [{string:lowercase(K), V} || {K, V} <- Headers].
