-module(repost_stream_ffi).

-export([request_body/8]).

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
