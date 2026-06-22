//// Streaming HTTPS PUT client. Caller drives the body chunk-by-chunk;
//// back-pressure is implicit (`send_chunk` blocks on a full kernel buffer).

import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/http
import gleam/result

pub type Conn

pub type StartError {
  StartConnectError(detail: String)
}

pub type SendError {
  SendErrorClosed
  SendErrorOther(detail: String)
}

pub type FinishError {
  FinishErrorClosed
  FinishErrorMalformed
  FinishErrorOther(detail: String)
}

pub type Response {
  Response(status: Int, headers: List(#(String, String)), body: BitArray)
}

@external(erlang, "repost_stream_ffi", "start")
fn ffi_start(
  scheme: http.Scheme,
  host: BitArray,
  port: Int,
  method: BitArray,
  path: BitArray,
  headers: List(#(BitArray, BitArray)),
  timeout_ms: Int,
) -> Result(Conn, Dynamic)

@external(erlang, "repost_stream_ffi", "send_chunk")
fn ffi_send_chunk(conn: Conn, data: BitArray) -> Result(Nil, Dynamic)

@external(erlang, "repost_stream_ffi", "finish")
fn ffi_finish(
  conn: Conn,
  timeout_ms: Int,
) -> Result(#(Int, List(#(BitArray, BitArray)), BitArray), Dynamic)

@external(erlang, "repost_stream_ffi", "close")
fn ffi_close(conn: Conn) -> Nil

pub fn start(
  scheme: http.Scheme,
  host: String,
  port: Int,
  method: String,
  path: String,
  headers: List(#(String, String)),
  timeout_ms: Int,
) -> Result(Conn, StartError) {
  ffi_start(
    scheme,
    bit_array.from_string(host),
    port,
    bit_array.from_string(method),
    bit_array.from_string(path),
    encode_headers(headers),
    timeout_ms,
  )
  |> result.map_error(fn(d) { StartConnectError(detail: dyn_to_string(d)) })
}

pub fn send_chunk(conn: Conn, data: BitArray) -> Result(Nil, SendError) {
  ffi_send_chunk(conn, data)
  |> result.map_error(send_error_from)
}

pub fn finish(conn: Conn, timeout_ms: Int) -> Result(Response, FinishError) {
  case ffi_finish(conn, timeout_ms) {
    Ok(#(status, headers, body)) ->
      Ok(Response(status:, headers: decode_headers(headers), body:))
    Error(d) -> Error(finish_error_from(d))
  }
}

pub fn close(conn: Conn) -> Nil {
  ffi_close(conn)
}

fn encode_headers(pairs: List(#(String, String))) -> List(#(BitArray, BitArray)) {
  case pairs {
    [] -> []
    [#(k, v), ..rest] -> [
      #(bit_array.from_string(k), bit_array.from_string(v)),
      ..encode_headers(rest)
    ]
  }
}

fn decode_headers(pairs: List(#(BitArray, BitArray))) -> List(#(String, String)) {
  case pairs {
    [] -> []
    [#(k, v), ..rest] -> [
      #(
        bit_array.to_string(k) |> result.unwrap(""),
        bit_array.to_string(v) |> result.unwrap(""),
      ),
      ..decode_headers(rest)
    ]
  }
}

fn send_error_from(d: Dynamic) -> SendError {
  case dyn_to_string(d) {
    "closed" -> SendErrorClosed
    other -> SendErrorOther(detail: other)
  }
}

fn finish_error_from(d: Dynamic) -> FinishError {
  case dyn_to_string(d) {
    "closed" -> FinishErrorClosed
    "malformed_response" -> FinishErrorMalformed
    other -> FinishErrorOther(detail: other)
  }
}

@external(erlang, "gleam@string", "inspect")
fn dyn_to_string(d: Dynamic) -> String
