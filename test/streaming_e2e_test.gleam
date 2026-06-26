//// End-to-end test for the pure-pipe streaming handler. Spins up the shim
//// and a fake R2 (both real mist servers); sends a chunked multipart POST
//// and asserts what each end sees.

import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http
import gleam/http/request as http_request
import gleam/http/response as http_response
import gleam/int
import gleam/list
import gleam/string
import mist

import repost/config
import repost/r2_stream
import repost/sigv4
import repost/streaming/pump
import repost/streaming/r2_put
import repost/streaming_handler

const shim_secret: String = "shim-secret-for-tests"

const shim_ak: String = "shim-app-key"

const shim_region: String = "auto"

// 2024-01-15 T00:00:00 UTC
const now_seconds: Int = 1_705_276_800

const date: String = "20240115"

const amz_date: String = "20240115T000000Z"

const credential: String = "shim-app-key/20240115/auto/s3/aws4_request"

fn test_config() -> config.Config {
  config.Config(
    shim_access_key_id: shim_ak,
    shim_secret_access_key: shim_secret,
    shim_region:,
    r2_account_id: "fake",
    r2_access_key_id: "AKIATEST",
    r2_secret_access_key: "r2-secret",
    r2_bucket: "destination-bucket",
    allowed_origins: ["https://outline.example.com"],
    max_upload_bytes: 1_048_576,
    shim_base_host: "",
    bind_interface: "127.0.0.1",
    port: 0,
  )
}

pub type Captured {
  Captured(
    method: http.Method,
    path: String,
    headers: List(#(String, String)),
    body: BitArray,
  )
}

fn build_policy_b64(content_length_range: String) -> String {
  let extra = case content_length_range {
    "" -> ""
    other -> "," <> other
  }
  build_policy_with_conditions(
    "{\"bucket\":\"my-bucket\"},"
    <> "[\"starts-with\",\"$key\",\"u/\"],"
    <> "[\"starts-with\",\"$Content-Type\",\"image/\"]"
    <> extra,
  )
}

fn build_policy_with_conditions(conditions_json: String) -> String {
  let json =
    "{\"expiration\":\"2025-01-01T00:00:00Z\",\"conditions\":["
    <> conditions_json
    <> "]}"
  bit_array.base64_encode(bit_array.from_string(json), True)
}

fn sign(policy_b64: String) -> String {
  let signing = sigv4.signing_key(shim_secret, date, shim_region, "s3")
  sigv4.hex(sigv4.hmac(bit_array.from_string(policy_b64), signing))
}

fn start_fake_r2() -> #(process.Subject(Captured), Int) {
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

fn start_shim(deps: pump.Deps) -> Int {
  let port_subj = process.new_subject()
  let assert Ok(_) =
    mist.new(streaming_handler.handle(_, deps))
    |> mist.bind("127.0.0.1")
    |> mist.port(0)
    |> mist.after_start(fn(p, _, _) { process.send(port_subj, p) })
    |> mist.start
  let assert Ok(port) = process.receive(port_subj, 5000)
  port
}

const boundary: String = "REPOSTBOUNDARY"

fn build_multipart_body(
  text_fields: List(#(String, String)),
  file_filename: String,
  file_ct: String,
  file_bytes: BitArray,
) -> BitArray {
  let crlf = "\r\n"
  let prelude = fn(name: String) {
    "--"
    <> boundary
    <> crlf
    <> "Content-Disposition: form-data; name=\""
    <> name
    <> "\""
    <> crlf
    <> crlf
  }
  let text_parts =
    list.fold(text_fields, <<>>, fn(acc, pair) {
      let #(name, value) = pair
      <<acc:bits, { prelude(name) <> value <> crlf }:utf8>>
    })
  let file_header =
    "--"
    <> boundary
    <> crlf
    <> "Content-Disposition: form-data; name=\"file\"; filename=\""
    <> file_filename
    <> "\""
    <> crlf
    <> "Content-Type: "
    <> file_ct
    <> crlf
    <> crlf
  let trailer = crlf <> "--" <> boundary <> "--" <> crlf
  <<text_parts:bits, file_header:utf8, file_bytes:bits, trailer:utf8>>
}

fn build_multipart_body_with_trailing(
  text_fields: List(#(String, String)),
  file_filename: String,
  file_ct: String,
  file_bytes: BitArray,
  trailing_fields: List(#(String, String)),
) -> BitArray {
  let crlf = "\r\n"
  let prelude = fn(name: String) {
    "--"
    <> boundary
    <> crlf
    <> "Content-Disposition: form-data; name=\""
    <> name
    <> "\""
    <> crlf
    <> crlf
  }
  let text_parts =
    list.fold(text_fields, <<>>, fn(acc, pair) {
      let #(name, value) = pair
      <<acc:bits, { prelude(name) <> value <> crlf }:utf8>>
    })
  let file_header =
    "--"
    <> boundary
    <> crlf
    <> "Content-Disposition: form-data; name=\"file\"; filename=\""
    <> file_filename
    <> "\""
    <> crlf
    <> "Content-Type: "
    <> file_ct
    <> crlf
    <> crlf
  let trailing_parts =
    list.fold(trailing_fields, <<>>, fn(acc, pair) {
      let #(name, value) = pair
      <<acc:bits, { prelude(name) <> value <> crlf }:utf8>>
    })
  let trailer = "--" <> boundary <> "--" <> crlf
  <<
    text_parts:bits,
    file_header:utf8,
    file_bytes:bits,
    crlf:utf8,
    trailing_parts:bits,
    trailer:utf8,
  >>
}

fn post_chunked(
  port: Int,
  bucket: String,
  origin: String,
  body: BitArray,
  chunk_size: Int,
) -> #(Int, List(#(String, String)), BitArray) {
  let host_header = "127.0.0.1:" <> int.to_string(port)
  let headers = [
    #("host", host_header),
    #("origin", origin),
    #("content-type", "multipart/form-data; boundary=" <> boundary),
    #("connection", "close"),
  ]
  let assert Ok(conn) =
    r2_stream.start(
      http.Http,
      "127.0.0.1",
      port,
      "POST",
      "/" <> bucket,
      headers,
      5000,
    )
  send_in_chunks(conn, body, chunk_size)
  let assert Ok(resp) = r2_stream.finish(conn, 10_000)
  r2_stream.close(conn)
  #(resp.status, resp.headers, resp.body)
}

fn post_without_origin(
  port: Int,
  bucket: String,
) -> #(Int, List(#(String, String)), BitArray) {
  let host_header = "127.0.0.1:" <> int.to_string(port)
  let headers = [
    #("host", host_header),
    #("connection", "close"),
  ]
  let assert Ok(conn) =
    r2_stream.start(
      http.Http,
      "127.0.0.1",
      port,
      "POST",
      "/" <> bucket,
      headers,
      5000,
    )
  let assert Ok(resp) = r2_stream.finish(conn, 10_000)
  r2_stream.close(conn)
  #(resp.status, resp.headers, resp.body)
}

/// Tolerates an early hang-up from the server, mirroring how real S3
/// clients behave.
fn send_in_chunks(conn: r2_stream.Conn, body: BitArray, chunk_size: Int) -> Nil {
  let total = bit_array.byte_size(body)
  case total {
    0 -> Nil
    _ -> {
      let take = case total < chunk_size {
        True -> total
        False -> chunk_size
      }
      let assert Ok(slice) = bit_array.slice(body, 0, take)
      let assert Ok(rest) = bit_array.slice(body, take, total - take)
      case r2_stream.send_chunk(conn, slice) {
        Error(_) -> Nil
        Ok(_) -> send_in_chunks(conn, rest, chunk_size)
      }
    }
  }
}

fn make_deps(r2_port: Int) -> pump.Deps {
  pump.Deps(
    config: test_config(),
    clock: fn() { now_seconds },
    endpoint: r2_put.Custom(scheme: http.Http, host: "127.0.0.1", port: r2_port),
  )
}

pub fn happy_path_chunked_request_chunked_to_r2_test() {
  let #(capture, r2_port) = start_fake_r2()
  let shim_port = start_shim(make_deps(r2_port))

  let p = build_policy_b64("[\"content-length-range\",1,1000000]")
  let payload = bit_array.from_string(repeat_string("PNG", 200))
  let body =
    build_multipart_body(
      [
        #("key", "u/photo.png"),
        #("Content-Type", "image/png"),
        #("policy", p),
        #("x-amz-algorithm", "AWS4-HMAC-SHA256"),
        #("x-amz-credential", credential),
        #("x-amz-date", amz_date),
        #("x-amz-signature", sign(p)),
      ],
      "photo.png",
      "image/png",
      payload,
    )

  // 41-byte client chunks make the streaming reader hop part boundaries.
  let #(status, headers, _resp_body) =
    post_chunked(
      shim_port,
      "my-bucket",
      "https://outline.example.com",
      body,
      41,
    )

  assert status == 204
  let assert Ok(etag) = list.key_find(headers, "etag")
  assert etag == "\"e2e-streamed\""
  let assert Ok(allow_origin) =
    list.key_find(headers, "access-control-allow-origin")
  assert allow_origin == "https://outline.example.com"

  // Verify R2 received exactly the bytes we sent.
  let assert Ok(captured) = process.receive(capture, 2000)
  assert captured.method == http.Put
  assert captured.path == "/destination-bucket/u/photo.png"
  assert captured.body == payload
  let assert Ok(content_sha) =
    list.key_find(captured.headers, "x-amz-content-sha256")
  assert content_sha == sigv4.sha256_hex(payload)
  let assert Ok(content_length) =
    list.key_find(captured.headers, "content-length")
  assert content_length == int.to_string(bit_array.byte_size(payload))
  assert list.key_find(captured.headers, "transfer-encoding") == Error(Nil)
  let assert Ok(content_type) = list.key_find(captured.headers, "content-type")
  assert content_type == "image/png"
  assert header_count(captured.headers, "host") == 1
}

pub fn aborts_when_content_length_range_upper_bound_exceeded_mid_stream_test() {
  let #(capture, r2_port) = start_fake_r2()
  let shim_port = start_shim(make_deps(r2_port))

  // Policy permits up to 100 bytes; we send 500.
  let p = build_policy_b64("[\"content-length-range\",1,100]")
  let payload = bit_array.from_string(repeat_string("X", 500))
  let body =
    build_multipart_body(
      [
        #("key", "u/big.bin"),
        #("Content-Type", "image/png"),
        #("policy", p),
        #("x-amz-algorithm", "AWS4-HMAC-SHA256"),
        #("x-amz-credential", credential),
        #("x-amz-date", amz_date),
        #("x-amz-signature", sign(p)),
      ],
      "big.bin",
      "image/png",
      payload,
    )

  let #(status, _headers, body_bytes) =
    post_chunked(
      shim_port,
      "my-bucket",
      "https://outline.example.com",
      body,
      32,
    )
  let assert Ok(body_str) = bit_array.to_string(body_bytes)

  assert status == 400
  assert string.contains(body_str, "<Code>EntityTooLarge</Code>")
  // The partial bytes R2 saw are non-deterministic, so we don't assert
  // against `capture`.
  let _ = capture
}

pub fn enforces_conditions_after_positive_length_minimum_test() {
  let #(_capture, r2_port) = start_fake_r2()
  let shim_port = start_shim(make_deps(r2_port))

  let p =
    build_policy_with_conditions(
      "{\"bucket\":\"my-bucket\"},"
      <> "[\"content-length-range\",1,1000000],"
      <> "[\"starts-with\",\"$key\",\"u/\"],"
      <> "[\"starts-with\",\"$Content-Type\",\"image/\"]",
    )
  let body =
    build_multipart_body(
      [
        #("key", "x/photo.png"),
        #("Content-Type", "image/png"),
        #("policy", p),
        #("x-amz-algorithm", "AWS4-HMAC-SHA256"),
        #("x-amz-credential", credential),
        #("x-amz-date", amz_date),
        #("x-amz-signature", sign(p)),
      ],
      "photo.png",
      "image/png",
      bit_array.from_string("data"),
    )

  let #(status, _headers, body_bytes) =
    post_chunked(
      shim_port,
      "my-bucket",
      "https://outline.example.com",
      body,
      64,
    )
  let assert Ok(body_str) = bit_array.to_string(body_bytes)

  assert status == 403
  assert string.contains(body_str, "<Code>AccessDenied</Code>")
}

pub fn rejects_fields_after_file_part_test() {
  let #(_capture, r2_port) = start_fake_r2()
  let shim_port = start_shim(make_deps(r2_port))

  let p = build_policy_b64("[\"content-length-range\",1,1000000]")
  let body =
    build_multipart_body_with_trailing(
      [
        #("key", "u/photo.png"),
        #("Content-Type", "image/png"),
        #("policy", p),
        #("x-amz-algorithm", "AWS4-HMAC-SHA256"),
        #("x-amz-credential", credential),
        #("x-amz-date", amz_date),
        #("x-amz-signature", sign(p)),
      ],
      "photo.png",
      "image/png",
      bit_array.from_string("data"),
      [#("acl", "private")],
    )

  let #(status, _headers, body_bytes) =
    post_chunked(
      shim_port,
      "my-bucket",
      "https://outline.example.com",
      body,
      64,
    )
  let assert Ok(body_str) = bit_array.to_string(body_bytes)

  assert status == 400
  assert string.contains(body_str, "<Code>InvalidRequest</Code>")
}

pub fn rejects_missing_origin_on_post_test() {
  let #(_capture, r2_port) = start_fake_r2()
  let shim_port = start_shim(make_deps(r2_port))

  let #(status, _headers, body_bytes) =
    post_without_origin(shim_port, "my-bucket")
  let assert Ok(body_str) = bit_array.to_string(body_bytes)

  assert status == 403
  assert string.contains(body_str, "<Code>AccessDenied</Code>")
}

pub fn rejects_disallowed_origin_on_preflight_test() {
  let #(_capture, r2_port) = start_fake_r2()
  let shim_port = start_shim(make_deps(r2_port))
  let host_header = "127.0.0.1:" <> int.to_string(shim_port)
  let assert Ok(conn) =
    r2_stream.start(
      http.Http,
      "127.0.0.1",
      shim_port,
      "OPTIONS",
      "/my-bucket",
      [
        #("host", host_header),
        #("origin", "https://attacker.example.com"),
        #("connection", "close"),
      ],
      5000,
    )
  let assert Ok(resp) = r2_stream.finish(conn, 5000)
  r2_stream.close(conn)
  assert resp.status == 403
  let assert Ok(body_str) = bit_array.to_string(resp.body)
  assert string.contains(body_str, "<Code>AccessDenied</Code>")
}

pub fn rejects_signature_mismatch_test() {
  let #(_capture, r2_port) = start_fake_r2()
  let shim_port = start_shim(make_deps(r2_port))
  let p = build_policy_b64("")
  let body =
    build_multipart_body(
      [
        #("key", "u/x"),
        #("Content-Type", "image/png"),
        #("policy", p),
        #("x-amz-algorithm", "AWS4-HMAC-SHA256"),
        #("x-amz-credential", credential),
        #("x-amz-date", amz_date),
        // Wrong sig.
        #("x-amz-signature", "deadbeef00"),
      ],
      "x",
      "image/png",
      bit_array.from_string("data"),
    )
  let #(status, _h, body_bytes) =
    post_chunked(
      shim_port,
      "my-bucket",
      "https://outline.example.com",
      body,
      64,
    )
  let assert Ok(body_str) = bit_array.to_string(body_bytes)
  assert status == 403
  assert string.contains(body_str, "<Code>SignatureDoesNotMatch</Code>")
}

pub fn accepts_content_type_without_space_before_boundary_test() {
  // RFC 7231 permits parameters with or without leading whitespace.
  let #(_capture, r2_port) = start_fake_r2()
  let shim_port = start_shim(make_deps(r2_port))
  let p = build_policy_b64("")
  let body =
    build_multipart_body(
      [
        #("key", "u/x"),
        #("Content-Type", "image/png"),
        #("policy", p),
        #("x-amz-algorithm", "AWS4-HMAC-SHA256"),
        #("x-amz-credential", credential),
        #("x-amz-date", amz_date),
        #("x-amz-signature", sign(p)),
      ],
      "x",
      "image/png",
      bit_array.from_string("data"),
    )
  // Build the request directly so we control the Content-Type byte-for-byte
  // (no space after `;`).
  let host_header = "127.0.0.1:" <> int.to_string(shim_port)
  let assert Ok(conn) =
    r2_stream.start(
      http.Http,
      "127.0.0.1",
      shim_port,
      "POST",
      "/my-bucket",
      [
        #("host", host_header),
        #("origin", "https://outline.example.com"),
        #("content-type", "multipart/form-data;boundary=" <> boundary),
        #("connection", "close"),
      ],
      5000,
    )
  send_in_chunks(conn, body, 64)
  let assert Ok(resp) = r2_stream.finish(conn, 5000)
  r2_stream.close(conn)
  assert resp.status == 204
}

pub fn accepts_quoted_boundary_test() {
  let #(_capture, r2_port) = start_fake_r2()
  let shim_port = start_shim(make_deps(r2_port))
  let p = build_policy_b64("")
  let body =
    build_multipart_body(
      [
        #("key", "u/x"),
        #("Content-Type", "image/png"),
        #("policy", p),
        #("x-amz-algorithm", "AWS4-HMAC-SHA256"),
        #("x-amz-credential", credential),
        #("x-amz-date", amz_date),
        #("x-amz-signature", sign(p)),
      ],
      "x",
      "image/png",
      bit_array.from_string("data"),
    )
  let host_header = "127.0.0.1:" <> int.to_string(shim_port)
  let assert Ok(conn) =
    r2_stream.start(
      http.Http,
      "127.0.0.1",
      shim_port,
      "POST",
      "/my-bucket",
      [
        #("host", host_header),
        #("origin", "https://outline.example.com"),
        #(
          "content-type",
          "multipart/form-data; boundary=\"" <> boundary <> "\"",
        ),
        #("connection", "close"),
      ],
      5000,
    )
  send_in_chunks(conn, body, 64)
  let assert Ok(resp) = r2_stream.finish(conn, 5000)
  r2_stream.close(conn)
  assert resp.status == 204
}

pub fn options_preflight_test() {
  let #(_capture, r2_port) = start_fake_r2()
  let shim_port = start_shim(make_deps(r2_port))
  let host_header = "127.0.0.1:" <> int.to_string(shim_port)
  let assert Ok(conn) =
    r2_stream.start(
      http.Http,
      "127.0.0.1",
      shim_port,
      "OPTIONS",
      "/my-bucket",
      [
        #("host", host_header),
        #("origin", "https://outline.example.com"),
        #("connection", "close"),
      ],
      5000,
    )
  let assert Ok(resp) = r2_stream.finish(conn, 5000)
  r2_stream.close(conn)
  assert resp.status == 204
  let assert Ok(allow_origin) =
    list.key_find(resp.headers, "access-control-allow-origin")
  assert allow_origin == "https://outline.example.com"
  let assert Ok(allow_methods) =
    list.key_find(resp.headers, "access-control-allow-methods")
  assert allow_methods == "POST"
}

fn repeat_string(s: String, n: Int) -> String {
  case n {
    0 -> ""
    _ -> s <> repeat_string(s, n - 1)
  }
}

fn header_count(headers: List(#(String, String)), name: String) -> Int {
  case headers {
    [] -> 0
    [#(k, _), ..rest] -> {
      let rest_count = header_count(rest, name)
      case string.lowercase(k) == string.lowercase(name) {
        True -> rest_count + 1
        False -> rest_count
      }
    }
  }
}
