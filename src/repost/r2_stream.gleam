import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/http
import gleam/result

pub type FinishError {
  FinishErrorClosed
  FinishErrorMalformed
  FinishErrorOther(detail: String)
}

pub type Response {
  Response(status: Int, headers: List(#(String, String)), body: BitArray)
}

@external(erlang, "repost_stream_ffi", "request_body")
fn ffi_request_body(
  scheme: http.Scheme,
  host: BitArray,
  port: Int,
  method: BitArray,
  path: BitArray,
  headers: List(#(BitArray, BitArray)),
  body: BitArray,
  timeout_ms: Int,
) -> Result(#(Int, List(#(BitArray, BitArray)), BitArray), Dynamic)

pub fn request_body(
  scheme: http.Scheme,
  host: String,
  port: Int,
  method: String,
  path: String,
  headers: List(#(String, String)),
  body: BitArray,
  timeout_ms: Int,
) -> Result(Response, FinishError) {
  case
    ffi_request_body(
      scheme,
      bit_array.from_string(host),
      port,
      bit_array.from_string(method),
      bit_array.from_string(path),
      encode_headers(headers),
      body,
      timeout_ms,
    )
  {
    Ok(#(status, headers, body)) ->
      Ok(Response(status:, headers: decode_headers(headers), body:))
    Error(d) -> Error(finish_error_from(d))
  }
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

fn finish_error_from(d: Dynamic) -> FinishError {
  case dyn_to_string(d) {
    "closed" -> FinishErrorClosed
    "malformed_response" -> FinishErrorMalformed
    other -> FinishErrorOther(detail: other)
  }
}

@external(erlang, "gleam@string", "inspect")
fn dyn_to_string(d: Dynamic) -> String
