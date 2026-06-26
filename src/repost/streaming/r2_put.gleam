//// Open and authorise a chunked PUT to R2 (or a custom endpoint in tests).

import gleam/bit_array
import gleam/http
import gleam/int
import gleam/list
import gleam/string

import repost/config.{type Config}
import repost/errors.{type ErrorResponse}
import repost/r2_stream
import repost/sigv4
import repost/streaming/uri
import repost/time

pub type Endpoint {
  R2Endpoint(account_id: String)
  Custom(scheme: http.Scheme, host: String, port: Int)
}

const open_timeout_ms: Int = 10_000

const request_timeout_ms: Int = 60_000

pub type Opened {
  Opened(conn: r2_stream.Conn, key: String)
}

pub fn open(
  endpoint: Endpoint,
  config: Config,
  key: String,
  content_type: Result(String, Nil),
  amz_date_seconds: Int,
) -> Result(Opened, ErrorResponse) {
  let #(scheme, host, port) = endpoint_parts(endpoint)
  let host_header = host_header_for(host, port, scheme)
  let path = "/" <> config.r2_bucket <> "/" <> uri.encode_path(key)
  let amz_date = time.format_amz_date(amz_date_seconds)

  let signed =
    sigv4.sign_put(sigv4.PutSignInput(
      access_key: config.r2_access_key_id,
      secret: config.r2_secret_access_key,
      region: "auto",
      service: "s3",
      host: host_header,
      canonical_uri: path,
      payload_sha256_hex: "UNSIGNED-PAYLOAD",
      amz_date:,
      content_type:,
      content_length: 0,
    ))
  // sign_put always emits content-length:0 for symmetry with the buffered
  // path; for chunked transfer it must be dropped or R2 will truncate at 0.
  let headers =
    transport_headers()
    |> list.append(strip_content_length(signed.headers))

  case
    r2_stream.start(scheme, host, port, "PUT", path, headers, open_timeout_ms)
  {
    Error(_) -> Error(errors.internal_error("could not open R2 connection"))
    Ok(conn) -> Ok(Opened(conn:, key:))
  }
}

pub fn put_buffered(
  endpoint: Endpoint,
  config: Config,
  key: String,
  content_type: Result(String, Nil),
  amz_date_seconds: Int,
  body: BitArray,
) -> Result(r2_stream.Response, ErrorResponse) {
  let #(scheme, host, port) = endpoint_parts(endpoint)
  let host_header = host_header_for(host, port, scheme)
  let path = "/" <> config.r2_bucket <> "/" <> uri.encode_path(key)
  let amz_date = time.format_amz_date(amz_date_seconds)
  let content_length = bit_array.byte_size(body)

  let signed =
    sigv4.sign_put(sigv4.PutSignInput(
      access_key: config.r2_access_key_id,
      secret: config.r2_secret_access_key,
      region: "auto",
      service: "s3",
      host: host_header,
      canonical_uri: path,
      payload_sha256_hex: sigv4.sha256_hex(body),
      amz_date:,
      content_type:,
      content_length:,
    ))
  let headers =
    buffered_transport_headers()
    |> list.append(signed.headers)

  case
    r2_stream.request_body(
      scheme,
      host,
      port,
      "PUT",
      path,
      headers,
      body,
      request_timeout_ms,
    )
  {
    Error(_) -> Error(errors.internal_error("R2 buffered PUT failed"))
    Ok(resp) -> Ok(resp)
  }
}

fn endpoint_parts(endpoint: Endpoint) -> #(http.Scheme, String, Int) {
  case endpoint {
    R2Endpoint(account_id:) -> #(
      http.Https,
      account_id <> ".r2.cloudflarestorage.com",
      443,
    )
    Custom(scheme:, host:, port:) -> #(scheme, host, port)
  }
}

fn host_header_for(host: String, port: Int, scheme: http.Scheme) -> String {
  case scheme, port {
    http.Https, 443 -> host
    http.Http, 80 -> host
    _, _ -> host <> ":" <> int.to_string(port)
  }
}

fn transport_headers() -> List(#(String, String)) {
  [
    #("connection", "close"),
    #("transfer-encoding", "chunked"),
    #("user-agent", "repost/1.0"),
  ]
}

fn buffered_transport_headers() -> List(#(String, String)) {
  [
    #("connection", "close"),
    #("user-agent", "repost/1.0"),
  ]
}

fn strip_content_length(
  headers: List(#(String, String)),
) -> List(#(String, String)) {
  list.filter(headers, fn(h) { string.lowercase(h.0) != "content-length" })
}
