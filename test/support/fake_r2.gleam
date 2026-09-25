import gleam/bytes_tree
import gleam/erlang/process
import gleam/http
import gleam/http/request as http_request
import gleam/http/response as http_response
import gleam/option.{type Option, None, Some}
import mist

pub type Captured {
  Captured(
    method: http.Method,
    path: String,
    query: Option(String),
    headers: List(#(String, String)),
    body: BitArray,
  )
}

pub type Failure {
  NoFailure
  FailUploadPart
  CompleteEmbeddedError
  FailUploadPartAndAbort
}

pub fn start() -> #(process.Subject(Captured), Int) {
  start_with_failure(NoFailure)
}

pub fn start_with_failure(
  failure: Failure,
) -> #(process.Subject(Captured), Int) {
  let capture = process.new_subject()
  let port_subj = process.new_subject()
  let assert Ok(_) =
    mist.new(fn(req: http_request.Request(mist.Connection)) {
      case mist.read_body(req, max_body_limit: 50_000_000) {
        Ok(req2) -> {
          process.send(
            capture,
            Captured(
              method: req2.method,
              path: req2.path,
              query: req2.query,
              headers: req2.headers,
              body: req2.body,
            ),
          )
          reply(req2.method, req2.query, failure)
        }
        Error(_) ->
          http_response.new(400)
          |> http_response.set_body(mist.Bytes(bytes_tree.from_string("bad")))
      }
    })
    |> mist.bind("127.0.0.1")
    |> mist.port(0)
    |> mist.after_start(fn(p, _, _) { process.send(port_subj, p) })
    |> mist.start
  let assert Ok(port) = process.receive(port_subj, 5000)
  #(capture, port)
}

fn reply(
  method: http.Method,
  query: Option(String),
  failure: Failure,
) -> http_response.Response(mist.ResponseData) {
  case method, query {
    http.Post, Some("uploads=") ->
      xml_reply(
        200,
        "<InitiateMultipartUploadResult><UploadId>fake-upload-id</UploadId></InitiateMultipartUploadResult>",
      )
    http.Put, Some(_) ->
      case failure {
        FailUploadPart | FailUploadPartAndAbort ->
          xml_reply(500, "<Error><Code>InternalError</Code></Error>")
        _ ->
          http_response.new(200)
          |> http_response.set_header("etag", "\"part-etag\"")
          |> http_response.set_body(mist.Bytes(bytes_tree.from_string("")))
      }
    http.Post, Some(_) ->
      case failure {
        CompleteEmbeddedError ->
          xml_reply(200, "<Error><Code>InternalError</Code></Error>")
        _ ->
          xml_reply(
            200,
            "<CompleteMultipartUploadResult><ETag>\"complete-etag\"</ETag></CompleteMultipartUploadResult>",
          )
      }
    http.Delete, Some(_) ->
      case failure {
        FailUploadPartAndAbort ->
          xml_reply(500, "<Error><Code>InternalError</Code></Error>")
        _ -> xml_reply(204, "")
      }
    http.Put, None ->
      http_response.new(200)
      |> http_response.set_header("etag", "\"e2e-streamed\"")
      |> http_response.set_body(mist.Bytes(bytes_tree.from_string("")))
    _, _ -> xml_reply(400, "bad")
  }
}

fn xml_reply(
  status: Int,
  body: String,
) -> http_response.Response(mist.ResponseData) {
  http_response.new(status)
  |> http_response.set_body(mist.Bytes(bytes_tree.from_string(body)))
}
