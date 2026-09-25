import gleam/http.{type Method}
import gleam/http/request.{Request}
import gleam/http/response.{type Response}
import gleam/httpc
import gleam/int
import gleam/list
import gleam/option.{None, Some}

import repost/sigv4
import repost/sigv4/uri
import repost/time

const request_timeout_ms: Int = 60_000

pub type Endpoint {
  R2Endpoint(account_id: String)
  Custom(scheme: http.Scheme, host: String, port: Int)
}

pub type R2Error {
  R2Unreachable(detail: httpc.HttpError)
  R2Status(status: Int, body: BitArray)
}

pub fn send(
  endpoint: Endpoint,
  creds: sigv4.SigningCredentials,
  method: Method,
  bucket: String,
  key: String,
  query: List(#(String, String)),
  headers: List(#(String, String)),
  body: BitArray,
  now: Int,
) -> Result(Response(BitArray), R2Error) {
  let #(scheme, host, port) = endpoint_parts(endpoint)
  let path = "/" <> bucket <> "/" <> uri.encode_path(key)
  let amz_date = time.format_amz_date(now)
  let host_header = host_header_for(host, port, scheme)
  let content_type = case list.key_find(headers, "content-type") {
    Ok(value) -> value
    Error(_) -> "application/octet-stream"
  }
  // httpc signs the default Content-Type for body requests even when the caller omits it.
  let headers = list.key_set(headers, "content-type", content_type)
  let signed =
    sigv4.sign(
      method,
      path,
      query,
      [#("host", host_header), ..headers],
      sigv4.sha256_hex(body),
      amz_date,
      creds,
    )
  // httpc derives Host and Content-Length from the URL and body.
  let outgoing =
    list.filter(signed, fn(header) {
      header.0 != "host" && header.0 != "content-length"
    })
  let request =
    Request(
      method:,
      headers: outgoing,
      body:,
      scheme:,
      host:,
      port: case scheme, port {
        http.Https, 443 -> None
        http.Http, 80 -> None
        _, _ -> Some(port)
      },
      path:,
      query: case query {
        [] -> None
        _ -> Some(sigv4.canonical_query(query))
      },
    )
  case
    httpc.dispatch_bits(
      httpc.configure() |> httpc.timeout(request_timeout_ms),
      request,
    )
  {
    Error(detail) -> Error(R2Unreachable(detail))
    Ok(response) if response.status >= 200 && response.status < 300 ->
      Ok(response)
    Ok(response) -> Error(R2Status(response.status, response.body))
  }
}

@internal
pub fn endpoint_parts(endpoint: Endpoint) -> #(http.Scheme, String, Int) {
  case endpoint {
    R2Endpoint(account_id:) -> #(
      http.Https,
      account_id <> ".r2.cloudflarestorage.com",
      443,
    )
    Custom(scheme:, host:, port:) -> #(scheme, host, port)
  }
}

@internal
pub fn host_header_for(host: String, port: Int, scheme: http.Scheme) -> String {
  case scheme, port {
    http.Https, 443 -> host
    http.Http, 80 -> host
    _, _ -> host <> ":" <> int.to_string(port)
  }
}
