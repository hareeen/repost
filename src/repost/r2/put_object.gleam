//// Send a buffered PUT to R2 (or a custom endpoint in tests).

import gleam/bit_array
import gleam/list

import repost/config.{type Config}
import repost/errors.{type ErrorResponse}
import repost/r2
import repost/r2_stream
import repost/sigv4
import repost/sigv4/uri
import repost/time

const request_timeout_ms: Int = 60_000

pub fn put_buffered(
  endpoint: r2.Endpoint,
  config: Config,
  key: String,
  content_type: Result(String, Nil),
  amz_date_seconds: Int,
  body: BitArray,
) -> Result(r2_stream.Response, ErrorResponse) {
  let #(scheme, host, port) = r2.endpoint_parts(endpoint)
  let host_header = r2.host_header_for(host, port, scheme)
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
    |> list.append(signed)

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

fn buffered_transport_headers() -> List(#(String, String)) {
  [
    #("connection", "close"),
    #("user-agent", "repost/1.0"),
  ]
}
