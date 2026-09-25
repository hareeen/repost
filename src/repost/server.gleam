//// Top-level mist handler: routes the request, dispatches to the streaming
//// upload loop, and forces `Connection: close` on every error so
//// mid-stream aborts (spec §10.2.3) are observable on the wire.

import gleam/http
import gleam/http/request as http_request
import gleam/http/response as http_response
import gleam/string
import mist

import repost/cors
import repost/errors.{type ErrorResponse}
import repost/multipart
import repost/multipart/boundary
import repost/router
import repost/server/response
import repost/upload

const stream_chunk_size: Int = 65_536

pub fn handle(
  req: http_request.Request(mist.Connection),
  deps: upload.Deps,
) -> http_response.Response(mist.ResponseData) {
  let origin = http_request.get_header(req, "origin")
  let decision = cors.evaluate(origin, deps.config.allowed_origins)

  let host = http_request.get_header(req, "host")
  let segments = http_request.path_segments(req)
  let response = case router.route(host, segments, deps.config.shim_base_host) {
    // Every upload lands in `r2_bucket`, so any other bucket name is
    // refused rather than silently redirected.
    router.BucketRoute(bucket:, remainder:) if bucket == deps.config.r2_bucket ->
      handle_bucket(req, deps, decision, bucket, remainder)
    router.BucketRoute(..) | router.NoRoute ->
      response.xml_error(decision, errors.no_such_bucket())
  }
  apply_connection_header(response, response.status >= 400 || wants_close(req))
}

fn wants_close(req: http_request.Request(mist.Connection)) -> Bool {
  case http_request.get_header(req, "connection") {
    Ok(value) -> string.lowercase(string.trim(value)) == "close"
    Error(_) -> False
  }
}

fn apply_connection_header(
  response: http_response.Response(mist.ResponseData),
  close: Bool,
) -> http_response.Response(mist.ResponseData) {
  case close {
    True -> http_response.set_header(response, "connection", "close")
    False -> response
  }
}

fn handle_bucket(
  req: http_request.Request(mist.Connection),
  deps: upload.Deps,
  decision: cors.OriginDecision,
  bucket: String,
  remainder: List(String),
) -> http_response.Response(mist.ResponseData) {
  case req.method, remainder {
    http.Options, [] -> handle_preflight(decision)
    http.Post, [] -> handle_upload(req, deps, decision, bucket)
    http.Options, _ | http.Post, _ ->
      response.xml_error(decision, errors.no_such_bucket())
    _, _ -> response.xml_error(decision, errors.method_not_allowed())
  }
}

fn handle_preflight(
  decision: cors.OriginDecision,
) -> http_response.Response(mist.ResponseData) {
  case decision {
    cors.Allowed(o) ->
      response.empty(204)
      |> response.apply_headers(cors.preflight_headers(o))
    cors.NoOrigin ->
      response.xml_error(decision, errors.access_denied("missing origin"))
    cors.Denied ->
      response.xml_error(decision, errors.access_denied("origin not allowed"))
  }
}

fn handle_upload(
  req: http_request.Request(mist.Connection),
  deps: upload.Deps,
  decision: cors.OriginDecision,
  bucket: String,
) -> http_response.Response(mist.ResponseData) {
  case decision {
    cors.Allowed(_) -> {
      case extract_boundary(req) {
        Error(err) -> response.xml_error(decision, err)
        Ok(b) ->
          case open_stream(req) {
            Error(err) -> response.xml_error(decision, err)
            Ok(reader) ->
              upload.run(multipart.new(reader, b), deps, decision, bucket)
          }
      }
    }
    cors.NoOrigin ->
      response.xml_error(decision, errors.access_denied("missing origin"))
    cors.Denied ->
      response.xml_error(decision, errors.access_denied("origin not allowed"))
  }
}

fn extract_boundary(
  req: http_request.Request(mist.Connection),
) -> Result(String, ErrorResponse) {
  case http_request.get_header(req, "content-type") {
    Error(_) ->
      Error(errors.invalid_request("missing Content-Type: multipart/form-data"))
    Ok(value) -> boundary.extract(value)
  }
}

fn open_stream(
  req: http_request.Request(mist.Connection),
) -> Result(multipart.Reader, ErrorResponse) {
  case mist.stream(req) {
    Error(_) -> Error(errors.invalid_request("could not read request body"))
    Ok(stream) -> Ok(adapt_mist_stream(stream))
  }
}

fn adapt_mist_stream(
  stream: fn(Int) -> Result(mist.Chunk, mist.ReadError),
) -> multipart.Reader {
  fn() {
    case stream(stream_chunk_size) {
      Error(_) -> multipart.ReaderError(detail: "transport read failed")
      Ok(mist.Done) -> multipart.ReaderEof
      Ok(mist.Chunk(data:, consume:)) ->
        multipart.ReaderChunk(data:, next: adapt_mist_stream(consume))
    }
  }
}
