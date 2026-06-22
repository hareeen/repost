//// SigV4 tests. Reference vectors are cross-validated against an
//// independent Python `hmac` implementation; see the constants below.

import gleam/bit_array
import repost/sigv4

const aws_example_secret: String = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"

const aws_example_date: String = "20151229"

const aws_example_region: String = "us-east-1"

/// Expected SigV4 signing key derived from the AWS example credentials.
/// Cross-validated against an independent Python `hmac` implementation; we
/// embed it here so the test catches any drift in our HMAC chain.
const expected_signing_key_hex: String = "7dfc1e2c4434dfa3f533d0ec4dbc415809c141e2ae85fbce3fd3db00c24aecad"

pub fn signing_key_matches_aws_vector_test() {
  let key =
    sigv4.signing_key(
      aws_example_secret,
      aws_example_date,
      aws_example_region,
      "s3",
    )
  assert sigv4.hex(key) == expected_signing_key_hex
}

const aws_example_post_policy_b64: String = "eyAiZXhwaXJhdGlvbiI6ICIyMDE1LTEyLTMwVDEyOjAwOjAwLjAwMFoiLA0KICAiY29uZGl0aW9ucyI6IFsNCiAgICB7ImJ1Y2tldCI6ICJzaWd2NGV4YW1wbGVidWNrZXQifSwNCiAgICBbInN0YXJ0cy13aXRoIiwgIiRrZXkiLCAidXNlci91c2VyMS8iXSwNCiAgICB7ImFjbCI6ICJwdWJsaWMtcmVhZCJ9LA0KICAgIHsic3VjY2Vzc19hY3Rpb25fcmVkaXJlY3QiOiAiaHR0cDovL3NpZ3Y0ZXhhbXBsZWJ1Y2tldC5zMy5hbWF6b25hd3MuY29tL3N1Y2Nlc3NmdWxfdXBsb2FkLmh0bWwifSwNCiAgICBbInN0YXJ0cy13aXRoIiwgIiRDb250ZW50LVR5cGUiLCAiaW1hZ2UvIl0sDQogICAgeyJ4LWFtei1tZXRhLXV1aWQiOiAiMTQzNjUxMjM2NTEyNzQifSwNCiAgICB7IngtYW16LXNlcnZlci1zaWRlLWVuY3J5cHRpb24iOiAiQUVTMjU2In0sDQogICAgWyJzdGFydHMtd2l0aCIsICIkeC1hbXotbWV0YS10YWciLCAiIl0sDQoNCiAgICB7IngtYW16LWNyZWRlbnRpYWwiOiAiQUtJQUlPU0ZPRE5ON0VYQU1QTEUvMjAxNTEyMjkvdXMtZWFzdC0xL3MzL2F3czRfcmVxdWVzdCJ9LA0KICAgIHsieC1hbXotYWxnb3JpdGhtIjogIkFXUzQtSE1BQy1TSEEyNTYifSwNCiAgICB7IngtYW16LWRhdGUiOiAiMjAxNTEyMjlUMDAwMDAwWiIgfQ0KICBdDQp9"

/// Expected hex signature for the policy above, derived from an independent
/// Python `hmac` implementation against the same secret/date/region.
const aws_example_post_signature: String = "e7318f0bfd7d86fb9ba81c314f62192ee2baf7273792ef01ffafeb430fc2fb68"

pub fn verify_post_signature_accepts_aws_vector_test() {
  assert sigv4.verify_post_signature(
      aws_example_post_policy_b64,
      aws_example_post_signature,
      aws_example_secret,
      aws_example_date,
      aws_example_region,
    )
    == Ok(Nil)
}

pub fn verify_post_signature_rejects_tampered_signature_test() {
  let tampered =
    "0000000000000000000000000000000000000000000000000000000000000000"
  assert sigv4.verify_post_signature(
      aws_example_post_policy_b64,
      tampered,
      aws_example_secret,
      aws_example_date,
      aws_example_region,
    )
    == Error(sigv4.PostSignatureMismatch)
}

pub fn verify_post_signature_rejects_tampered_policy_test() {
  let tampered = aws_example_post_policy_b64 <> "AA"
  assert sigv4.verify_post_signature(
      tampered,
      aws_example_post_signature,
      aws_example_secret,
      aws_example_date,
      aws_example_region,
    )
    == Error(sigv4.PostSignatureMismatch)
}

pub fn verify_post_signature_constant_time_compare_accepts_uppercase_test() {
  // AWS clients sometimes uppercase the hex signature; we lowercase before
  // comparing.
  let upper = "E7318F0BFD7D86FB9BA81C314F62192EE2BAF7273792EF01FFAFEB430FC2FB68"
  assert sigv4.verify_post_signature(
      aws_example_post_policy_b64,
      upper,
      aws_example_secret,
      aws_example_date,
      aws_example_region,
    )
    == Ok(Nil)
}

pub fn parse_credential_test() {
  let raw = "AKIAIOSFODNN7EXAMPLE/20151229/us-east-1/s3/aws4_request"
  assert sigv4.parse_credential(raw)
    == Ok(sigv4.Credential(
      access_key: "AKIAIOSFODNN7EXAMPLE",
      date: "20151229",
      region: "us-east-1",
      service: "s3",
    ))
}

pub fn parse_credential_rejects_wrong_terminator_test() {
  let raw = "AKIAIOSFODNN7EXAMPLE/20151229/us-east-1/s3/aws4_other"
  assert sigv4.parse_credential(raw) == Error(sigv4.MalformedCredential)
}

pub fn parse_credential_rejects_too_few_parts_test() {
  assert sigv4.parse_credential("AK/20151229/us-east-1/s3")
    == Error(sigv4.MalformedCredential)
}

pub fn empty_sha256_constant_test() {
  assert sigv4.empty_sha256_hex == sigv4.sha256_hex(<<>>)
}

pub fn sha256_known_value_test() {
  // SHA256("abc") = ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
  assert sigv4.sha256_hex(bit_array.from_string("abc"))
    == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
}

pub fn sign_put_matches_python_reference_test() {
  let input =
    sigv4.PutSignInput(
      access_key: "AKIDEXAMPLE",
      secret: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
      region: "us-east-1",
      service: "s3",
      host: "example-bucket.s3.amazonaws.com",
      canonical_uri: "/uploads/photo.png",
      payload_sha256_hex: sigv4.sha256_hex(bit_array.from_string("hi")),
      amz_date: "20240101T000000Z",
      content_type: Ok("application/octet-stream"),
      content_length: 2,
    )
  let out = sigv4.sign_put(input)
  let expected =
    "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20240101/us-east-1/s3/aws4_request,SignedHeaders=content-type;host;x-amz-content-sha256;x-amz-date,Signature=7ebab692f8c54b347d609ccf878aa832576e952c61e7ecff0583c5b35ff0cc94"
  assert get_header(out.headers, "authorization") == Ok(expected)
}

fn get_header(
  headers: List(#(String, String)),
  name: String,
) -> Result(String, Nil) {
  case headers {
    [] -> Error(Nil)
    [#(k, v), ..rest] ->
      case k == name {
        True -> Ok(v)
        False -> get_header(rest, name)
      }
  }
}

pub fn sign_put_round_trip_test() {
  let input =
    sigv4.PutSignInput(
      access_key: "AKIDEXAMPLE",
      secret: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
      region: "us-east-1",
      service: "s3",
      host: "example-bucket.s3.amazonaws.com",
      canonical_uri: "/uploads/photo.png",
      payload_sha256_hex: sigv4.sha256_hex(bit_array.from_string("hi")),
      amz_date: "20240101T000000Z",
      content_type: Ok("application/octet-stream"),
      content_length: 2,
    )
  let out_a = sigv4.sign_put(input)
  let out_b = sigv4.sign_put(input)
  assert out_a == out_b
  // Ensure required headers are present.
  let names = list_keys(out_a.headers)
  assert list_contains(names, "authorization")
  assert list_contains(names, "host")
  assert list_contains(names, "x-amz-content-sha256")
  assert list_contains(names, "x-amz-date")
  assert list_contains(names, "content-length")
  assert list_contains(names, "content-type")
}

pub fn sign_put_omits_content_type_when_absent_test() {
  let input =
    sigv4.PutSignInput(
      access_key: "AKIDEXAMPLE",
      secret: "secret",
      region: "us-east-1",
      service: "s3",
      host: "example.r2.cloudflarestorage.com",
      canonical_uri: "/bucket/key",
      payload_sha256_hex: sigv4.empty_sha256_hex,
      amz_date: "20240101T000000Z",
      content_type: Error(Nil),
      content_length: 0,
    )
  let out = sigv4.sign_put(input)
  let names = list_keys(out.headers)
  assert !list_contains(names, "content-type")
  assert list_contains(names, "authorization")
}

fn list_keys(headers: List(#(String, String))) -> List(String) {
  case headers {
    [] -> []
    [#(k, _), ..rest] -> [k, ..list_keys(rest)]
  }
}

fn list_contains(items: List(String), needle: String) -> Bool {
  case items {
    [] -> False
    [h, ..rest] ->
      case h == needle {
        True -> True
        False -> list_contains(rest, needle)
      }
  }
}
