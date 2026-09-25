//// Send a buffered PUT to R2 (or a custom endpoint in tests).

import gleam/http
import gleam/http/response.{type Response}
import gleam/int

import repost/config.{type Config}
import repost/errors.{type ErrorResponse}
import repost/r2

pub fn put_buffered(
  endpoint: r2.Endpoint,
  config: Config,
  key: String,
  content_type: Result(String, Nil),
  amz_date_seconds: Int,
  body: BitArray,
) -> Result(Response(BitArray), ErrorResponse) {
  let headers = case content_type {
    Ok(value) -> [#("content-type", value)]
    Error(_) -> []
  }
  case
    r2.send(
      endpoint,
      r2.credentials(config),
      http.Put,
      config.r2_bucket,
      key,
      [],
      headers,
      body,
      amz_date_seconds,
    )
  {
    Ok(response) -> Ok(response)
    Error(r2.R2Status(status:, ..)) ->
      Error(errors.internal_error(
        "R2 returned status " <> int.to_string(status),
      ))
    Error(r2.R2Unreachable(_)) ->
      Error(errors.internal_error("R2 buffered PUT failed"))
  }
}
