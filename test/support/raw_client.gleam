import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/list

pub type Response {
  Response(status: Int, headers: List(#(String, String)), body: BitArray)
}

pub type Error {
  RequestError(detail: String)
}

@external(erlang, "raw_client", "request")
fn ffi_request(
  port: Int,
  method: BitArray,
  path: BitArray,
  headers: List(#(BitArray, BitArray)),
  body: BitArray,
  chunk_size: Int,
  timeout_ms: Int,
) -> Result(#(Int, List(#(BitArray, BitArray)), BitArray), Dynamic)

pub fn request(
  port: Int,
  method: String,
  path: String,
  headers: List(#(String, String)),
  body: BitArray,
  chunk_size: Int,
  timeout_ms: Int,
) -> Result(Response, Error) {
  let encoded_headers =
    headers
    |> list.map(fn(pair) {
      let #(name, value) = pair
      #(bit_array.from_string(name), bit_array.from_string(value))
    })
  case
    ffi_request(
      port,
      bit_array.from_string(method),
      bit_array.from_string(path),
      encoded_headers,
      body,
      chunk_size,
      timeout_ms,
    )
  {
    Ok(#(status, headers, body)) -> {
      let decoded_headers =
        headers
        |> list.map(fn(pair) {
          let #(name, value) = pair
          let assert Ok(decoded_name) = bit_array.to_string(name)
          let assert Ok(decoded_value) = bit_array.to_string(value)
          #(decoded_name, decoded_value)
        })
      Ok(Response(status:, headers: decoded_headers, body:))
    }
    Error(reason) -> Error(RequestError(detail: dyn_to_string(reason)))
  }
}

@external(erlang, "gleam@string", "inspect")
fn dyn_to_string(d: Dynamic) -> String
