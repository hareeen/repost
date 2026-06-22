//// AWS SigV4: POST-policy verification (browser → shim) and PUT signing
//// (shim → R2). See AWS docs `sigv4-HTTPPOSTConstructPolicy.html` and
//// `general/latest/gr/sigv4_signing.html` for the reference algorithms.

import gleam/bit_array
import gleam/crypto
import gleam/int
import gleam/list
import gleam/order.{type Order}
import gleam/string

pub type Credential {
  Credential(access_key: String, date: String, region: String, service: String)
}

pub type CredentialError {
  MalformedCredential
}

pub fn parse_credential(raw: String) -> Result(Credential, CredentialError) {
  case string.split(raw, "/") {
    [ak, date, region, service, "aws4_request"] ->
      Ok(Credential(
        access_key: ak,
        date: date,
        region: region,
        service: service,
      ))
    _ -> Error(MalformedCredential)
  }
}

pub fn signing_key(
  secret: String,
  date: String,
  region: String,
  service: String,
) -> BitArray {
  let k0 = bit_array.from_string("AWS4" <> secret)
  let k1 = hmac(bit_array.from_string(date), k0)
  let k2 = hmac(bit_array.from_string(region), k1)
  let k3 = hmac(bit_array.from_string(service), k2)
  hmac(bit_array.from_string("aws4_request"), k3)
}

pub fn hmac(data: BitArray, key: BitArray) -> BitArray {
  crypto.hmac(data, crypto.Sha256, key)
}

pub fn hex(input: BitArray) -> String {
  string.lowercase(bit_array.base16_encode(input))
}

pub fn secure_equal(left: String, right: String) -> Bool {
  crypto.secure_compare(
    bit_array.from_string(left),
    bit_array.from_string(right),
  )
}

pub fn sha256_hex(input: BitArray) -> String {
  hex(crypto.hash(crypto.Sha256, input))
}

pub const empty_sha256_hex: String = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

pub type PostVerifyError {
  PostSignatureMismatch
}

/// Verify an S3 POST policy signature. The string-to-sign is the
/// **raw Base64-encoded policy** verbatim — not the decoded JSON.
pub fn verify_post_signature(
  base64_policy: String,
  provided_signature: String,
  shim_secret: String,
  date: String,
  region: String,
) -> Result(Nil, PostVerifyError) {
  let signing = signing_key(shim_secret, date, region, "s3")
  let expected = hex(hmac(bit_array.from_string(base64_policy), signing))
  case secure_equal(expected, string.lowercase(provided_signature)) {
    True -> Ok(Nil)
    False -> Error(PostSignatureMismatch)
  }
}

pub type PutSignInput {
  PutSignInput(
    access_key: String,
    secret: String,
    region: String,
    service: String,
    /// Host header value; include the port unless it's the scheme default.
    host: String,
    /// Path starting with `/{bucket}/{key}`, segments already URI-encoded.
    canonical_uri: String,
    /// Lowercase hex SHA-256 of the request body, OR the literal string
    /// `UNSIGNED-PAYLOAD` for streaming uploads.
    payload_sha256_hex: String,
    /// Timestamp in `YYYYMMDDTHHMMSSZ` format.
    amz_date: String,
    content_type: Result(String, Nil),
    content_length: Int,
  )
}

pub type PutSignOutput {
  PutSignOutput(headers: List(#(String, String)))
}

pub fn sign_put(input: PutSignInput) -> PutSignOutput {
  let date = string.slice(input.amz_date, at_index: 0, length: 8)
  let credential_scope =
    date <> "/" <> input.region <> "/" <> input.service <> "/aws4_request"

  let base_headers = [
    #("host", input.host),
    #("x-amz-content-sha256", input.payload_sha256_hex),
    #("x-amz-date", input.amz_date),
  ]
  let with_content_type = case input.content_type {
    Ok(ct) -> [#("content-type", ct), ..base_headers]
    Error(_) -> base_headers
  }
  let signed = list.sort(with_content_type, by: header_compare)
  let signed_headers_str = signed_headers_string(signed)
  let canonical_headers_str = canonical_headers_string(signed)

  let canonical_request =
    "PUT\n"
    <> input.canonical_uri
    <> "\n\n"
    <> canonical_headers_str
    <> "\n"
    <> signed_headers_str
    <> "\n"
    <> input.payload_sha256_hex

  let string_to_sign =
    "AWS4-HMAC-SHA256\n"
    <> input.amz_date
    <> "\n"
    <> credential_scope
    <> "\n"
    <> sha256_hex(bit_array.from_string(canonical_request))

  let key = signing_key(input.secret, date, input.region, input.service)
  let signature = hex(hmac(bit_array.from_string(string_to_sign), key))

  let authorization =
    "AWS4-HMAC-SHA256 Credential="
    <> input.access_key
    <> "/"
    <> credential_scope
    <> ",SignedHeaders="
    <> signed_headers_str
    <> ",Signature="
    <> signature

  let outgoing =
    list.append(signed, [
      #("authorization", authorization),
      #("content-length", int.to_string(input.content_length)),
    ])
  PutSignOutput(headers: outgoing)
}

fn header_compare(left: #(String, String), right: #(String, String)) -> Order {
  string.compare(left.0, right.0)
}

fn signed_headers_string(headers: List(#(String, String))) -> String {
  headers
  |> list.map(fn(h) { h.0 })
  |> string.join(";")
}

fn canonical_headers_string(headers: List(#(String, String))) -> String {
  headers
  |> list.map(fn(h) {
    let #(k, v) = h
    k <> ":" <> normalise_header_value(v) <> "\n"
  })
  |> string.concat
}

fn normalise_header_value(v: String) -> String {
  v
  |> string.trim
  |> collapse_internal_whitespace("", False)
}

fn collapse_internal_whitespace(
  remaining: String,
  acc: String,
  in_space: Bool,
) -> String {
  case string.pop_grapheme(remaining) {
    Error(_) -> acc
    Ok(#(c, rest)) ->
      case is_space(c) {
        True ->
          case in_space {
            True -> collapse_internal_whitespace(rest, acc, True)
            False -> collapse_internal_whitespace(rest, acc <> " ", True)
          }
        False -> collapse_internal_whitespace(rest, acc <> c, False)
      }
  }
}

fn is_space(c: String) -> Bool {
  case c {
    " " | "\t" -> True
    _ -> False
  }
}
