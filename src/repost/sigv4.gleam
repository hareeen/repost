//// AWS SigV4: POST-policy verification (browser → shim) and request signing
//// (shim → R2). See AWS docs `sigv4-HTTPPOSTConstructPolicy.html` and
//// `general/latest/gr/sigv4_signing.html` for the reference algorithms.

import gleam/bit_array
import gleam/crypto
import gleam/http.{type Method}
import gleam/list
import gleam/order.{type Order, Eq}
import gleam/string
import repost/sigv4/uri

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

pub type SigningCredentials {
  SigningCredentials(
    access_key: String,
    secret: String,
    region: String,
    service: String,
  )
}

pub fn canonical_query(query: List(#(String, String))) -> String {
  query
  |> list.map(fn(pair) {
    #(uri.encode_segment(pair.0), uri.encode_segment(pair.1))
  })
  |> list.sort(by: fn(left, right) {
    case string.compare(left.0, right.0) {
      Eq -> string.compare(left.1, right.1)
      other -> other
    }
  })
  |> list.map(fn(pair) { pair.0 <> "=" <> pair.1 })
  |> string.join("&")
}

pub fn sign(
  method: Method,
  canonical_uri: String,
  query: List(#(String, String)),
  headers: List(#(String, String)),
  payload_sha256_hex: String,
  amz_date: String,
  creds: SigningCredentials,
) -> List(#(String, String)) {
  let date = string.slice(amz_date, at_index: 0, length: 8)
  let credential_scope =
    date <> "/" <> creds.region <> "/" <> creds.service <> "/aws4_request"

  let signed =
    [
      #("x-amz-content-sha256", payload_sha256_hex),
      #("x-amz-date", amz_date),
      ..headers
    ]
    |> list.sort(by: header_compare)
  let signed_headers_str = signed_headers_string(signed)
  let canonical_headers_str = canonical_headers_string(signed)

  let canonical_request =
    http.method_to_string(method)
    <> "\n"
    <> canonical_uri
    <> "\n"
    <> canonical_query(query)
    <> "\n"
    <> canonical_headers_str
    <> "\n"
    <> signed_headers_str
    <> "\n"
    <> payload_sha256_hex

  let string_to_sign =
    "AWS4-HMAC-SHA256\n"
    <> amz_date
    <> "\n"
    <> credential_scope
    <> "\n"
    <> sha256_hex(bit_array.from_string(canonical_request))

  let key = signing_key(creds.secret, date, creds.region, creds.service)
  let signature = hex(hmac(bit_array.from_string(string_to_sign), key))

  let authorization =
    "AWS4-HMAC-SHA256 Credential="
    <> creds.access_key
    <> "/"
    <> credential_scope
    <> ",SignedHeaders="
    <> signed_headers_str
    <> ",Signature="
    <> signature

  list.append(signed, [#("authorization", authorization)])
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
