//// End-to-end test for the pure-pipe streaming handler. Spins up the shim
//// and a fake R2 (both real mist servers); sends a chunked multipart POST
//// and asserts what each end sees.

import gleam/bit_array
import gleam/erlang/process
import gleam/http
import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/string
import mist

import repost/config
import repost/r2
import repost/server
import repost/sigv4
import repost/upload
import support/fake_r2
import support/raw_client

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
    r2_bucket: "my-bucket",
    allowed_origins: ["https://outline.example.com"],
    max_upload_bytes: 1_048_576,
    shim_base_host: "",
    bind_interface: "127.0.0.1",
    port: 0,
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

fn start_shim(deps: upload.Deps) -> Int {
  let port_subj = process.new_subject()
  let assert Ok(_) =
    mist.new(server.handle(_, deps))
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
  let assert Ok(resp) =
    raw_client.request(
      port,
      "POST",
      "/" <> bucket,
      headers,
      body,
      chunk_size,
      10_000,
    )
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
  let assert Ok(resp) =
    raw_client.request(port, "POST", "/" <> bucket, headers, <<>>, 64, 10_000)
  #(resp.status, resp.headers, resp.body)
}

fn make_deps(r2_port: Int) -> upload.Deps {
  make_deps_with_part_size(r2_port, 5 * 1024 * 1024)
}

fn make_deps_with_part_size(r2_port: Int, part_size: Int) -> upload.Deps {
  upload.Deps(
    config: test_config(),
    clock: fn() { now_seconds },
    endpoint: r2.Custom(scheme: http.Http, host: "127.0.0.1", port: r2_port),
    part_size:,
  )
}

fn post_file(
  port: Int,
  payload: BitArray,
  range: String,
) -> #(Int, List(#(String, String)), BitArray) {
  let p = build_policy_b64(range)
  let body =
    build_multipart_body(
      [
        #("key", "u/file.bin"),
        #("Content-Type", "image/png"),
        #("policy", p),
        #("x-amz-algorithm", "AWS4-HMAC-SHA256"),
        #("x-amz-credential", credential),
        #("x-amz-date", amz_date),
        #("x-amz-signature", sign(p)),
      ],
      "file.bin",
      "image/png",
      payload,
    )
  post_chunked(port, "my-bucket", "https://outline.example.com", body, 41)
}

pub fn happy_path_chunked_request_chunked_to_r2_test() {
  let #(capture, r2_port) = fake_r2.start()
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
  assert captured.path == "/my-bucket/u/photo.png"
  assert captured.body == payload
  let assert Ok(content_sha) =
    list.key_find(captured.headers, "x-amz-content-sha256")
  assert content_sha == sigv4.sha256_hex(payload)
  let assert Ok(content_length) =
    list.key_find(captured.headers, "content-length")
  assert content_length == int.to_string(bit_array.byte_size(payload))
  assert header_count(captured.headers, "content-length") == 1
  assert list.key_find(captured.headers, "transfer-encoding") == Error(Nil)
  let assert Ok(content_type) = list.key_find(captured.headers, "content-type")
  assert content_type == "image/png"
  assert header_count(captured.headers, "host") == 1
  assert header_count(captured.headers, "content-type") == 1
}

pub fn aborts_when_content_length_range_upper_bound_exceeded_mid_stream_test() {
  let #(capture, r2_port) = fake_r2.start()
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
  let #(_capture, r2_port) = fake_r2.start()
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
  let #(_capture, r2_port) = fake_r2.start()
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

pub fn rejects_bucket_other_than_r2_bucket_test() {
  let #(_capture, r2_port) = fake_r2.start()
  let shim_port = start_shim(make_deps(r2_port))

  let #(status, _headers, body_bytes) =
    post_without_origin(shim_port, "other-bucket")
  let assert Ok(body_str) = bit_array.to_string(body_bytes)

  assert status == 404
  assert string.contains(body_str, "<Code>NoSuchBucket</Code>")
}

pub fn rejects_empty_key_test() {
  let #(capture, r2_port) = fake_r2.start()
  let shim_port = start_shim(make_deps(r2_port))

  let p =
    build_policy_with_conditions(
      "{\"bucket\":\"my-bucket\"},"
      <> "[\"starts-with\",\"$key\",\"\"],"
      <> "[\"starts-with\",\"$Content-Type\",\"image/\"]",
    )
  let body =
    build_multipart_body(
      [
        #("key", ""),
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

  assert status == 400
  assert string.contains(body_str, "<Code>InvalidRequest</Code>")
  assert process.receive(capture, 200) == Error(Nil)
}

pub fn rejects_flood_of_unauthenticated_fields_test() {
  let #(_capture, r2_port) = fake_r2.start()
  let shim_port = start_shim(make_deps(r2_port))

  let fields =
    int.range(from: 0, to: 200, with: [], run: fn(acc, i) {
      [#("x-flood-" <> int.to_string(i), ""), ..acc]
    })
  let body =
    build_multipart_body(fields, "x", "image/png", bit_array.from_string("d"))

  let #(status, _headers, body_bytes) =
    post_chunked(
      shim_port,
      "my-bucket",
      "https://outline.example.com",
      body,
      256,
    )
  let assert Ok(body_str) = bit_array.to_string(body_bytes)

  assert status == 400
  assert string.contains(body_str, "form fields exceeded soft cap")
}

pub fn rejects_missing_origin_on_post_test() {
  let #(_capture, r2_port) = fake_r2.start()
  let shim_port = start_shim(make_deps(r2_port))

  let #(status, _headers, body_bytes) =
    post_without_origin(shim_port, "my-bucket")
  let assert Ok(body_str) = bit_array.to_string(body_bytes)

  assert status == 403
  assert string.contains(body_str, "<Code>AccessDenied</Code>")
}

pub fn rejects_disallowed_origin_on_preflight_test() {
  let #(_capture, r2_port) = fake_r2.start()
  let shim_port = start_shim(make_deps(r2_port))
  let host_header = "127.0.0.1:" <> int.to_string(shim_port)
  let assert Ok(resp) =
    raw_client.request(
      shim_port,
      "OPTIONS",
      "/my-bucket",
      [
        #("host", host_header),
        #("origin", "https://attacker.example.com"),
        #("connection", "close"),
      ],
      <<>>,
      64,
      5000,
    )
  assert resp.status == 403
  let assert Ok(body_str) = bit_array.to_string(resp.body)
  assert string.contains(body_str, "<Code>AccessDenied</Code>")
}

pub fn rejects_signature_mismatch_test() {
  let #(_capture, r2_port) = fake_r2.start()
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
  let #(_capture, r2_port) = fake_r2.start()
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
  let assert Ok(resp) =
    raw_client.request(
      shim_port,
      "POST",
      "/my-bucket",
      [
        #("host", host_header),
        #("origin", "https://outline.example.com"),
        #("content-type", "multipart/form-data;boundary=" <> boundary),
        #("connection", "close"),
      ],
      body,
      64,
      5000,
    )
  assert resp.status == 204
}

pub fn accepts_quoted_boundary_test() {
  let #(_capture, r2_port) = fake_r2.start()
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
  let assert Ok(resp) =
    raw_client.request(
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
      body,
      64,
      5000,
    )
  assert resp.status == 204
}

pub fn options_preflight_test() {
  let #(_capture, r2_port) = fake_r2.start()
  let shim_port = start_shim(make_deps(r2_port))
  let host_header = "127.0.0.1:" <> int.to_string(shim_port)
  let assert Ok(resp) =
    raw_client.request(
      shim_port,
      "OPTIONS",
      "/my-bucket",
      [
        #("host", host_header),
        #("origin", "https://outline.example.com"),
        #("connection", "close"),
      ],
      <<>>,
      64,
      5000,
    )
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

pub fn smaller_than_part_uses_single_put_test() {
  let #(capture, r2_port) = fake_r2.start()
  let shim = start_shim(make_deps_with_part_size(r2_port, 16))
  let payload = bit_array.from_string("short")
  let #(status, headers, _) = post_file(shim, payload, "")
  assert status == 204
  assert list.key_find(headers, "etag") == Ok("\"e2e-streamed\"")
  let assert Ok(request) = process.receive(capture, 2000)
  assert request.method == http.Put
  assert request.body == payload
  assert process.receive(capture, 100) == Error(Nil)
}

pub fn exactly_one_part_uses_single_put_test() {
  let #(capture, r2_port) = fake_r2.start()
  let shim = start_shim(make_deps_with_part_size(r2_port, 16))
  let payload = bit_array.from_string("0123456789abcdef")
  let #(status, headers, _) = post_file(shim, payload, "")
  assert status == 204
  assert list.key_find(headers, "etag") == Ok("\"e2e-streamed\"")
  let assert Ok(request) = process.receive(capture, 2000)
  assert request.method == http.Put
  assert request.body == payload
  assert process.receive(capture, 100) == Error(Nil)
}

pub fn multipart_parts_are_ordered_and_byte_exact_test() {
  let #(capture, r2_port) = fake_r2.start()
  let shim = start_shim(make_deps_with_part_size(r2_port, 16))
  let payload =
    bit_array.from_string(
      "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ",
    )
  let #(status, headers, _) = post_file(shim, payload, "")
  assert status == 204
  assert list.key_find(headers, "etag") == Ok("\"complete-etag\"")
  let assert Ok(created) = process.receive(capture, 2000)
  assert created.method == http.Post
  let assert Ok(first) = process.receive(capture, 2000)
  let assert Ok(second) = process.receive(capture, 2000)
  let assert Ok(third) = process.receive(capture, 2000)
  let assert Ok(tail) = process.receive(capture, 2000)
  let assert Ok(completed) = process.receive(capture, 2000)
  assert first.query == Some("partNumber=1&uploadId=fake-upload-id")
  assert second.query == Some("partNumber=2&uploadId=fake-upload-id")
  assert third.query == Some("partNumber=3&uploadId=fake-upload-id")
  assert tail.query == Some("partNumber=4&uploadId=fake-upload-id")
  assert bit_array.byte_size(first.body) == 16
  assert bit_array.byte_size(second.body) == 16
  assert bit_array.byte_size(third.body) == 16
  assert bit_array.concat([first.body, second.body, third.body, tail.body])
    == payload
  assert completed.method == http.Post
  assert process.receive(capture, 100) == Error(Nil)
}

pub fn upper_bound_after_create_aborts_test() {
  let #(capture, r2_port) = fake_r2.start()
  let shim = start_shim(make_deps_with_part_size(r2_port, 4096))
  let payload = bit_array.from_string(string.repeat("x", 100_000))
  let #(status, _, body) =
    post_file(shim, payload, "[\"content-length-range\",1,75000]")
  assert status == 400
  let assert Ok(body_text) = bit_array.to_string(body)
  assert string.contains(body_text, "<Code>EntityTooLarge</Code>")
  let assert Ok(created) = process.receive(capture, 2000)
  assert created.method == http.Post
  let assert Ok(part) = process.receive(capture, 2000)
  assert part.method == http.Put
  assert receive_until_abort(capture, 20)
}

pub fn lower_bound_after_create_aborts_test() {
  let #(capture, r2_port) = fake_r2.start()
  let shim = start_shim(make_deps_with_part_size(r2_port, 16))
  let payload = bit_array.from_string(repeat_string("x", 40))
  let #(status, _, body) =
    post_file(shim, payload, "[\"content-length-range\",50,100]")
  assert status == 403
  let assert Ok(body_text) = bit_array.to_string(body)
  assert string.contains(body_text, "content-length-range")
  let assert Ok(created) = process.receive(capture, 2000)
  assert created.method == http.Post
  let assert Ok(first) = process.receive(capture, 2000)
  assert first.method == http.Put
  let assert Ok(second) = process.receive(capture, 2000)
  assert second.method == http.Put
  let assert Ok(aborted) = process.receive(capture, 2000)
  assert aborted.method == http.Delete
}

pub fn failed_upload_part_aborts_and_returns_502_test() {
  let #(capture, r2_port) = fake_r2.start_with_failure(fake_r2.FailUploadPart)
  let shim = start_shim(make_deps_with_part_size(r2_port, 16))
  let #(status, _, body) =
    post_file(shim, bit_array.from_string(repeat_string("x", 40)), "")
  assert status == 502
  let assert Ok(body_text) = bit_array.to_string(body)
  assert string.contains(body_text, "R2 UploadPart failed")
  let assert Ok(created) = process.receive(capture, 2000)
  assert created.method == http.Post
  let assert Ok(failed) = process.receive(capture, 2000)
  assert failed.method == http.Put
  let assert Ok(aborted) = process.receive(capture, 2000)
  assert aborted.method == http.Delete
}

pub fn failed_complete_aborts_and_returns_502_test() {
  let #(capture, r2_port) =
    fake_r2.start_with_failure(fake_r2.CompleteEmbeddedError)
  let shim = start_shim(make_deps_with_part_size(r2_port, 16))
  let #(status, _, body) =
    post_file(shim, bit_array.from_string(repeat_string("x", 40)), "")
  assert status == 502
  let assert Ok(body_text) = bit_array.to_string(body)
  assert string.contains(
    body_text,
    "R2 CompleteMultipartUpload returned InternalError",
  )
  let assert Ok(_) = process.receive(capture, 2000)
  let assert Ok(_) = process.receive(capture, 2000)
  let assert Ok(_) = process.receive(capture, 2000)
  let assert Ok(_) = process.receive(capture, 2000)
  let assert Ok(complete) = process.receive(capture, 2000)
  assert complete.method == http.Post
  let assert Ok(aborted) = process.receive(capture, 2000)
  assert aborted.method == http.Delete
}

fn receive_until_abort(
  capture: process.Subject(fake_r2.Captured),
  remaining: Int,
) -> Bool {
  case remaining {
    0 -> False
    _ ->
      case process.receive(capture, 2000) {
        Ok(request) if request.method == http.Delete -> True
        Ok(_) -> receive_until_abort(capture, remaining - 1)
        Error(_) -> False
      }
  }
}

pub fn abort_failure_preserves_original_error_and_adds_context_test() {
  let #(capture, r2_port) =
    fake_r2.start_with_failure(fake_r2.FailUploadPartAndAbort)
  let shim = start_shim(make_deps_with_part_size(r2_port, 16))
  let #(status, _, body) =
    post_file(shim, bit_array.from_string(repeat_string("x", 40)), "")
  assert status == 502
  let assert Ok(body_text) = bit_array.to_string(body)
  assert string.contains(
    body_text,
    "R2 UploadPart failed; abort of upload failed",
  )
  let assert Ok(created) = process.receive(capture, 2000)
  assert created.method == http.Post
  let assert Ok(failed) = process.receive(capture, 2000)
  assert failed.method == http.Put
  let assert Ok(aborted) = process.receive(capture, 2000)
  assert aborted.method == http.Delete
}
