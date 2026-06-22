//// Live integration test for the streaming HTTPS PUT client.
//// Runs against a local mist server pretending to be R2 (over plain HTTP).

import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http
import gleam/http/request as http_request
import gleam/http/response as http_response
import gleam/int
import gleam/list
import mist

import repost/r2_stream

pub type Captured {
  Captured(headers: List(#(String, String)), body: BitArray)
}

fn fake_chunked_r2(
  capture: process.Subject(Captured),
  port_subj: process.Subject(Int),
) -> Int {
  let assert Ok(_) =
    mist.new(fn(req: http_request.Request(mist.Connection)) {
      case mist.read_body(req, max_body_limit: 50_000_000) {
        Ok(req2) -> {
          process.send(
            capture,
            Captured(headers: req2.headers, body: req2.body),
          )
          http_response.new(200)
          |> http_response.set_header("etag", "\"streamed\"")
          |> http_response.set_header("content-type", "text/plain")
          |> http_response.set_body(mist.Bytes(bytes_tree.from_string("ok")))
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
  port
}

pub fn streaming_put_chunks_arrive_intact_test() {
  let capture = process.new_subject()
  let port_subj = process.new_subject()
  let port = fake_chunked_r2(capture, port_subj)

  let assert Ok(conn) =
    r2_stream.start(
      http.Http,
      "127.0.0.1",
      port,
      "PUT",
      "/bucket/streamed-key",
      [
        #("host", "127.0.0.1:" <> int.to_string(port)),
        #("content-type", "application/octet-stream"),
        #("connection", "close"),
      ],
      5000,
    )
  let assert Ok(_) = r2_stream.send_chunk(conn, bit_array.from_string("hello "))
  let assert Ok(_) = r2_stream.send_chunk(conn, bit_array.from_string("strea"))
  let assert Ok(_) = r2_stream.send_chunk(conn, bit_array.from_string("ming!"))

  let assert Ok(resp) = r2_stream.finish(conn, 5000)
  assert resp.status == 200
  let assert Ok(etag) = list.key_find(resp.headers, "etag")
  assert etag == "\"streamed\""
  r2_stream.close(conn)

  let assert Ok(captured) = process.receive(capture, 1000)
  assert captured.body == bit_array.from_string("hello streaming!")
}

pub fn streaming_put_empty_body_test() {
  let capture = process.new_subject()
  let port_subj = process.new_subject()
  let port = fake_chunked_r2(capture, port_subj)

  let assert Ok(conn) =
    r2_stream.start(
      http.Http,
      "127.0.0.1",
      port,
      "PUT",
      "/bucket/empty",
      [
        #("host", "127.0.0.1:" <> int.to_string(port)),
        #("connection", "close"),
      ],
      5000,
    )
  let assert Ok(resp) = r2_stream.finish(conn, 5000)
  assert resp.status == 200
  r2_stream.close(conn)

  let assert Ok(captured) = process.receive(capture, 1000)
  assert captured.body == <<>>
}
