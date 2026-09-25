import gleam/bit_array
import gleam/erlang/process
import gleam/http
import gleam/option.{Some}

import repost/config
import repost/errors
import repost/r2
import repost/upload/sink
import support/fake_r2

fn test_config() -> config.Config {
  config.Config(
    shim_access_key_id: "shim",
    shim_secret_access_key: "secret",
    shim_region: "auto",
    r2_account_id: "fake",
    r2_access_key_id: "AKIATEST",
    r2_secret_access_key: "r2-secret",
    r2_bucket: "my-bucket",
    allowed_origins: [],
    max_upload_bytes: 1_048_576,
    shim_base_host: "",
    bind_interface: "127.0.0.1",
    port: 0,
  )
}

pub fn one_chunk_yields_ordered_equal_parts_and_tail_test() {
  let #(capture, port) = fake_r2.start()
  let upload =
    sink.new(
      r2.Custom(scheme: http.Http, host: "127.0.0.1", port:),
      test_config(),
      "key",
      Ok("image/png"),
      fn() { 1_705_276_800 },
      4,
    )
  let assert Ok(upload) =
    sink.push(upload, bit_array.from_string("abcdefghijk"))
  let assert Ok(Ok(etag)) = sink.finish(upload)
  assert etag == "\"complete-etag\""
  let assert Ok(created) = process.receive(capture, 2000)
  assert created.method == http.Post
  let assert Ok(first) = process.receive(capture, 2000)
  let assert Ok(second) = process.receive(capture, 2000)
  let assert Ok(tail) = process.receive(capture, 2000)
  assert first.query == Some("partNumber=1&uploadId=fake-upload-id")
  assert second.query == Some("partNumber=2&uploadId=fake-upload-id")
  assert tail.query == Some("partNumber=3&uploadId=fake-upload-id")
  assert first.body == bit_array.from_string("abcd")
  assert second.body == bit_array.from_string("efgh")
  assert tail.body == bit_array.from_string("ijk")
  let assert Ok(completed) = process.receive(capture, 2000)
  assert completed.method == http.Post
}

pub fn abort_before_create_keeps_original_error_test() {
  let #(capture, port) = fake_r2.start()
  let upload =
    sink.new(
      r2.Custom(scheme: http.Http, host: "127.0.0.1", port:),
      test_config(),
      "key",
      Error(Nil),
      fn() { 1_705_276_800 },
      4,
    )
  let original = errors.entity_too_large()
  let #(aborted, response) = sink.abort(upload, original)
  assert response == original
  let #(_, repeated) = sink.abort(aborted, original)
  assert repeated == original
  assert process.receive(capture, 100) == Error(Nil)
}
