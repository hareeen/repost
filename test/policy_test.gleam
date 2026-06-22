//// Policy decoding (base64 → JSON → Conditions).

import gleam/bit_array
import repost/policy

fn b64(s: String) -> String {
  bit_array.base64_encode(bit_array.from_string(s), True)
}

pub fn decodes_simple_policy_test() {
  let json =
    "{\"expiration\":\"2024-01-01T00:00:00Z\",\"conditions\":[{\"bucket\":\"my-bucket\"}]}"
  let assert Ok(p) = policy.decode_policy(b64(json))
  assert p.expiration == "2024-01-01T00:00:00Z"
  assert p.conditions == [policy.Eq(field: "bucket", value: "my-bucket")]
}

pub fn decodes_starts_with_test() {
  let json =
    "{\"expiration\":\"2024-01-01T00:00:00Z\",\"conditions\":[[\"starts-with\",\"$key\",\"user/\"]]}"
  let assert Ok(p) = policy.decode_policy(b64(json))
  assert p.conditions == [policy.StartsWith(field: "key", prefix: "user/")]
}

pub fn decodes_eq_array_form_test() {
  let json =
    "{\"expiration\":\"2024-01-01T00:00:00Z\",\"conditions\":[[\"eq\",\"$acl\",\"private\"]]}"
  let assert Ok(p) = policy.decode_policy(b64(json))
  assert p.conditions == [policy.Eq(field: "acl", value: "private")]
}

pub fn decodes_content_length_range_test() {
  let json =
    "{\"expiration\":\"2024-01-01T00:00:00Z\",\"conditions\":[[\"content-length-range\",1,1048576]]}"
  let assert Ok(p) = policy.decode_policy(b64(json))
  assert p.conditions == [policy.ContentLengthRange(min: 1, max: 1_048_576)]
}

pub fn decodes_combined_conditions_in_order_test() {
  let json =
    "{\"expiration\":\"2024-01-01T00:00:00Z\",\"conditions\":["
    <> "{\"bucket\":\"b\"},"
    <> "[\"starts-with\",\"$key\",\"u/\"],"
    <> "[\"content-length-range\",0,1024]"
    <> "]}"
  let assert Ok(p) = policy.decode_policy(b64(json))
  assert p.conditions
    == [
      policy.Eq(field: "bucket", value: "b"),
      policy.StartsWith(field: "key", prefix: "u/"),
      policy.ContentLengthRange(min: 0, max: 1024),
    ]
}

pub fn rejects_invalid_base64_test() {
  assert policy.decode_policy("not valid base 64 ###")
    == Error(policy.Base64Decode)
}

pub fn rejects_invalid_json_test() {
  let bad = b64("{not json")
  let assert Error(policy.JsonSyntax) = policy.decode_policy(bad)
}

pub fn rejects_unknown_operator_test() {
  let json =
    "{\"expiration\":\"2024-01-01T00:00:00Z\",\"conditions\":[[\"like\",\"$key\",\"u/\"]]}"
  let assert Error(policy.Schema(_)) = policy.decode_policy(b64(json))
}

pub fn rejects_field_without_dollar_test() {
  let json =
    "{\"expiration\":\"2024-01-01T00:00:00Z\",\"conditions\":[[\"eq\",\"acl\",\"private\"]]}"
  let assert Error(policy.Schema(_)) = policy.decode_policy(b64(json))
}

pub fn rejects_negative_content_length_test() {
  let json =
    "{\"expiration\":\"2024-01-01T00:00:00Z\",\"conditions\":[[\"content-length-range\",-1,10]]}"
  let assert Error(policy.Schema(_)) = policy.decode_policy(b64(json))
}

pub fn rejects_inverted_content_length_test() {
  let json =
    "{\"expiration\":\"2024-01-01T00:00:00Z\",\"conditions\":[[\"content-length-range\",100,1]]}"
  let assert Error(policy.Schema(_)) = policy.decode_policy(b64(json))
}

pub fn rejects_multi_key_object_condition_test() {
  let json =
    "{\"expiration\":\"2024-01-01T00:00:00Z\",\"conditions\":[{\"a\":\"1\",\"b\":\"2\"}]}"
  let assert Error(policy.Schema(_)) = policy.decode_policy(b64(json))
}

pub fn lowercases_field_names_test() {
  let json =
    "{\"expiration\":\"2024-01-01T00:00:00Z\",\"conditions\":[[\"starts-with\",\"$Content-Type\",\"image/\"]]}"
  let assert Ok(p) = policy.decode_policy(b64(json))
  assert p.conditions
    == [policy.StartsWith(field: "content-type", prefix: "image/")]
}
