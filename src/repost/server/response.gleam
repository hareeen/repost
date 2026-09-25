//// Mist response builders for the streaming handler.

import gleam/bytes_tree
import gleam/http/response as http_response
import gleam/list
import mist

import repost/cors
import repost/errors.{type ErrorResponse}

pub fn success(
  decision: cors.OriginDecision,
  etag: Result(String, Nil),
) -> http_response.Response(mist.ResponseData) {
  let cors_h = case decision {
    cors.Allowed(o) -> cors.success_headers(o)
    _ -> []
  }
  let with_etag = case etag {
    Ok(e) -> [#("etag", e), ..cors_h]
    Error(_) -> cors_h
  }
  empty(204) |> apply_headers(with_etag)
}

pub fn xml_error(
  decision: cors.OriginDecision,
  err: ErrorResponse,
) -> http_response.Response(mist.ResponseData) {
  http_response.new(errors.status(err.kind))
  |> http_response.set_header("content-type", "application/xml")
  |> http_response.set_body(
    mist.Bytes(bytes_tree.from_string(errors.to_xml(err))),
  )
  |> apply_headers(cors.error_headers(decision))
}

pub fn empty(status: Int) -> http_response.Response(mist.ResponseData) {
  http_response.new(status)
  |> http_response.set_body(mist.Bytes(bytes_tree.new()))
}

pub fn apply_headers(
  response: http_response.Response(mist.ResponseData),
  headers: List(#(String, String)),
) -> http_response.Response(mist.ResponseData) {
  list.fold(headers, response, fn(r, h) {
    http_response.set_header(r, h.0, h.1)
  })
}
