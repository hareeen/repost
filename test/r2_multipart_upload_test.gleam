import gleam/bit_array
import gleam/erlang/process
import gleam/http
import gleam/list
import gleam/option.{Some}

import repost/r2
import repost/r2/multipart_upload as multipart
import repost/sigv4
import support/fake_r2

const now: Int = 1_705_276_800

fn creds() -> sigv4.SigningCredentials {
  sigv4.SigningCredentials(
    access_key: "AKIATEST",
    secret: "r2-secret",
    region: "auto",
    service: "s3",
  )
}

fn endpoint(port: Int) -> r2.Endpoint {
  r2.Custom(scheme: http.Http, host: "127.0.0.1", port:)
}

fn number(value: Int) -> multipart.PartNumber {
  let assert Ok(part_number) = multipart.part_number(value)
  part_number
}

pub fn multipart_sequence_signing_and_xml_test() {
  let #(capture, port) = fake_r2.start()
  let endpoint = endpoint(port)
  let creds = creds()
  let assert Ok(id) =
    multipart.create(
      endpoint,
      creds,
      "bucket",
      "folder/object",
      Ok("image/png"),
      now,
    )
  let assert Ok(created) = process.receive(capture, 2000)
  assert created.method == http.Post
  assert created.path == "/bucket/folder/object"
  assert created.query == Some("uploads=")
  assert list.key_find(created.headers, "content-type") == Ok("image/png")

  let body = bit_array.from_string("first part")
  let assert Ok(part) =
    multipart.upload_part(
      endpoint,
      creds,
      "bucket",
      "folder/object",
      id,
      number(1),
      body,
      now,
    )
  assert part.etag == "\"part-etag\""
  let assert Ok(uploaded) = process.receive(capture, 2000)
  assert uploaded.method == http.Put
  assert uploaded.query == Some("partNumber=1&uploadId=fake-upload-id")
  assert uploaded.body == body
  assert list.key_find(uploaded.headers, "x-amz-content-sha256")
    == Ok(sigv4.sha256_hex(body))

  let assert Ok(etag) =
    multipart.complete(
      endpoint,
      creds,
      "bucket",
      "folder/object",
      id,
      [
        multipart.PartEtag(number(2), "second & <tag> \"quoted\" 'apostrophe'"),
        part,
      ],
      now,
    )
  assert etag == "\"complete-etag\""
  let assert Ok(completed) = process.receive(capture, 2000)
  assert completed.method == http.Post
  assert completed.query == Some("uploadId=fake-upload-id")
  assert list.key_find(completed.headers, "content-type")
    == Ok("application/xml")
  let assert Ok(xml_body) = bit_array.to_string(completed.body)
  assert xml_body
    == "<CompleteMultipartUpload><Part><PartNumber>1</PartNumber><ETag>&quot;part-etag&quot;</ETag></Part><Part><PartNumber>2</PartNumber><ETag>second &amp; &lt;tag&gt; &quot;quoted&quot; &apos;apostrophe&apos;</ETag></Part></CompleteMultipartUpload>"

  assert multipart.abort(endpoint, creds, "bucket", "folder/object", id, now)
    == Ok(Nil)
  let assert Ok(aborted) = process.receive(capture, 2000)
  assert aborted.method == http.Delete
  assert aborted.query == Some("uploadId=fake-upload-id")
}

pub fn upload_part_status_error_is_preserved_test() {
  let #(capture, port) = fake_r2.start_with_failure(fake_r2.FailUploadPart)
  let endpoint = endpoint(port)
  let assert Ok(id) =
    multipart.create(endpoint, creds(), "bucket", "key", Ok("text/plain"), now)
  let assert Ok(_) = process.receive(capture, 2000)
  let result =
    multipart.upload_part(
      endpoint,
      creds(),
      "bucket",
      "key",
      id,
      number(1),
      bit_array.from_string("abc"),
      now,
    )
  let assert Error(multipart.SendFailed(r2.R2Status(status, _))) = result
  assert status == 500
}

pub fn complete_detects_error_inside_200_response_test() {
  let #(capture, port) =
    fake_r2.start_with_failure(fake_r2.CompleteEmbeddedError)
  let endpoint = endpoint(port)
  let assert Ok(id) =
    multipart.create(endpoint, creds(), "bucket", "key", Ok("text/plain"), now)
  let assert Ok(_) = process.receive(capture, 2000)
  assert multipart.complete(endpoint, creds(), "bucket", "key", id, [], now)
    == Error(multipart.CompleteError("InternalError"))
}

pub fn part_number_bounds_test() {
  assert multipart.part_number(0) == Error(multipart.PartNumberOutOfRange(0))
  assert multipart.part_number(10_001)
    == Error(multipart.PartNumberOutOfRange(10_001))
  assert multipart.part_number(10_000) == Ok(number(10_000))
}
