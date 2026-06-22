//// Top-level mist handler: routes the request, dispatches to the streaming
//// pump for uploads, and forces `Connection: close` on every error so
//// mid-stream aborts (spec §10.2.3) are observable on the wire.

import gleam/http
import gleam/http/request as http_request
import gleam/http/response as http_response
import gleam/string
import mist

import repost/config.{type Config}
import repost/cors
import repost/errors.{type ErrorResponse}
import repost/multipart_stream as ms
import repost/router
import repost/streaming/boundary
import repost/streaming/mist_response
import repost/streaming/pump

pub fn default_deps(config: Config) -> pump.Deps {
  pump.default_deps(config)
}

const stream_chunk_size: Int = 65_536

pub fn handle(
  req: http_request.Request(mist.Connection),
  deps: pump.Deps,
) -> http_response.Response(mist.ResponseData) {
  let origin = http_request.get_header(req, "origin")
  let decision = cors.evaluate(origin, deps.config.allowed_origins)

  let host = http_request.get_header(req, "host")
  let segments = http_request.path_segments(req)
  let response = case router.route(host, segments, deps.config.shim_base_host) {
    router.NoRoute -> mist_response.xml_error(decision, errors.no_such_bucket())
    router.BucketRoute(bucket:, remainder:) ->
      handle_bucket(req, deps, decision, bucket, remainder)
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
  deps: pump.Deps,
  decision: cors.OriginDecision,
  bucket: String,
  remainder: List(String),
) -> http_response.Response(mist.ResponseData) {
  case req.method, remainder {
    http.Options, [] -> handle_preflight(decision)
    http.Post, [] -> handle_upload(req, deps, decision, bucket)
    http.Options, _ | http.Post, _ ->
      mist_response.xml_error(decision, errors.no_such_bucket())
    _, _ -> mist_response.xml_error(decision, errors.method_not_allowed())
  }
}

fn handle_preflight(
  decision: cors.OriginDecision,
) -> http_response.Response(mist.ResponseData) {
  case decision {
    cors.Allowed(o) ->
      mist_response.empty(204)
      |> mist_response.apply_headers(cors.preflight_headers(o))
    cors.NoOrigin ->
      mist_response.xml_error(decision, errors.access_denied("missing origin"))
    cors.Denied ->
      mist_response.xml_error(
        decision,
        errors.access_denied("origin not allowed"),
      )
  }
}

fn handle_upload(
  req: http_request.Request(mist.Connection),
  deps: pump.Deps,
  decision: cors.OriginDecision,
  bucket: String,
) -> http_response.Response(mist.ResponseData) {
  case decision {
    cors.Allowed(_) -> {
      case extract_boundary(req) {
        Error(err) -> mist_response.xml_error(decision, err)
        Ok(b) ->
          case open_stream(req) {
            Error(err) -> mist_response.xml_error(decision, err)
            Ok(reader) -> pump.run(ms.new(reader, b), deps, decision, bucket)
          }
      }
    }
    cors.NoOrigin ->
      mist_response.xml_error(decision, errors.access_denied("missing origin"))
    cors.Denied ->
      mist_response.xml_error(
        decision,
        errors.access_denied("origin not allowed"),
      )
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
) -> Result(ms.Reader, ErrorResponse) {
  case mist.stream(req) {
    Error(_) -> Error(errors.invalid_request("could not read request body"))
    Ok(stream) -> Ok(adapt_mist_stream(stream))
  }
}

fn adapt_mist_stream(
  stream: fn(Int) -> Result(mist.Chunk, mist.ReadError),
) -> ms.Reader {
  fn() {
    case stream(stream_chunk_size) {
      Error(_) -> ms.ReaderError(detail: "transport read failed")
      Ok(mist.Done) -> ms.ReaderEof
      Ok(mist.Chunk(data:, consume:)) ->
        ms.ReaderChunk(data:, next: adapt_mist_stream(consume))
    }
  }
}
