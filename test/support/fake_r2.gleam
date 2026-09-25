import gleam/bytes_tree
import gleam/erlang/process
import gleam/http
import gleam/http/request as http_request
import gleam/http/response as http_response
import mist

pub type Captured {
  Captured(
    method: http.Method,
    path: String,
    headers: List(#(String, String)),
    body: BitArray,
  )
}

pub fn start() -> #(process.Subject(Captured), Int) {
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
              headers: req2.headers,
              body: req2.body,
            ),
          )
          http_response.new(200)
          |> http_response.set_header("etag", "\"e2e-streamed\"")
          |> http_response.set_body(mist.Bytes(bytes_tree.from_string("")))
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
