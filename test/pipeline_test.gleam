//// Validation pipeline tests with a frozen clock.

import gleam/bit_array
import repost/errors
import repost/pipeline
import repost/policy
import repost/sigv4

const shim_secret: String = "test-shim-secret"

const shim_ak: String = "shim-app-key"

const shim_region: String = "auto"

const date: String = "20240115"

const amz_date: String = "20240115T000000Z"

const credential: String = "shim-app-key/20240115/auto/s3/aws4_request"

// Frozen "now": well before the policy's expiration of 2025-01-01.
const now: Int = 1_705_276_800

fn build_policy_b64(extra_conditions_json: String) -> String {
  let conds = case extra_conditions_json {
    "" -> ""
    other -> "," <> other
  }
  let json =
    "{\"expiration\":\"2025-01-01T00:00:00Z\",\"conditions\":["
    <> "{\"bucket\":\"my-bucket\"},"
    <> "[\"starts-with\",\"$key\",\"u/\"]"
    <> conds
    <> "]}"
  bit_array.base64_encode(bit_array.from_string(json), True)
}

fn sign(policy_b64: String) -> String {
  let signing = sigv4.signing_key(shim_secret, date, shim_region, "s3")
  sigv4.hex(sigv4.hmac(bit_array.from_string(policy_b64), signing))
}

fn base_inputs(
  policy_b64: String,
  extra: List(#(String, String)),
  file_size: Int,
) -> pipeline.Inputs {
  let raw = [
    #("key", "u/photo.png"),
    #("policy", policy_b64),
    #("x-amz-algorithm", "AWS4-HMAC-SHA256"),
    #("x-amz-credential", credential),
    #("x-amz-date", amz_date),
    #("x-amz-signature", sign(policy_b64)),
    #("file", ""),
    ..extra
  ]
  pipeline.Inputs(
    bucket: "my-bucket",
    fields: policy.build_field_map(raw),
    raw_values: raw,
    file_size:,
    now_seconds: now,
    shim_access_key_id: shim_ak,
    shim_secret_access_key: shim_secret,
    shim_region: shim_region,
    max_upload_bytes: 26_214_400,
  )
}

pub fn happy_path_test() {
  let p = build_policy_b64("")
  let inputs = base_inputs(p, [], 1024)
  let assert Ok(validated) = pipeline.run(inputs)
  assert validated.bucket == "my-bucket"
  assert validated.key == "u/photo.png"
}

pub fn missing_required_field_returns_invalid_request_test() {
  let p = build_policy_b64("")
  let inputs = base_inputs(p, [], 1024)
  let stripped =
    pipeline.Inputs(
      ..inputs,
      fields: policy.build_field_map([
        #("policy", p),
        #("x-amz-algorithm", "AWS4-HMAC-SHA256"),
        #("x-amz-credential", credential),
        #("x-amz-date", amz_date),
        #("x-amz-signature", sign(p)),
      ]),
    )
  let assert Error(err) = pipeline.run(stripped)
  assert errors.code(err.kind) == "InvalidRequest"
}

pub fn wrong_signature_test() {
  let p = build_policy_b64("")
  let inputs = base_inputs(p, [], 1024)
  let bad =
    pipeline.Inputs(
      ..inputs,
      fields: policy.build_field_map([
        #("key", "u/photo.png"),
        #("policy", p),
        #("x-amz-algorithm", "AWS4-HMAC-SHA256"),
        #("x-amz-credential", credential),
        #("x-amz-date", amz_date),
        #("x-amz-signature", "0000000000"),
        #("file", ""),
      ]),
    )
  let assert Error(err) = pipeline.run(bad)
  assert errors.code(err.kind) == "SignatureDoesNotMatch"
}

pub fn wrong_access_key_returns_signature_mismatch_test() {
  let p = build_policy_b64("")
  let inputs = base_inputs(p, [], 1024)
  let bad_cred = "wrong-key/20240115/auto/s3/aws4_request"
  let mutated =
    pipeline.Inputs(
      ..inputs,
      fields: policy.build_field_map([
        #("key", "u/photo.png"),
        #("policy", p),
        #("x-amz-algorithm", "AWS4-HMAC-SHA256"),
        #("x-amz-credential", bad_cred),
        #("x-amz-date", amz_date),
        #("x-amz-signature", sign(p)),
        #("file", ""),
      ]),
    )
  let assert Error(err) = pipeline.run(mutated)
  assert errors.code(err.kind) == "SignatureDoesNotMatch"
}

pub fn expired_policy_returns_access_denied_test() {
  let p = build_policy_b64("")
  let inputs = base_inputs(p, [], 1024)
  // Force "now" past the 2025-01-01 expiration.
  let future = pipeline.Inputs(..inputs, now_seconds: 9_999_999_999)
  let assert Error(err) = pipeline.run(future)
  assert errors.code(err.kind) == "AccessDenied"
}

pub fn condition_mismatch_returns_access_denied_test() {
  let p = build_policy_b64("")
  let inputs = base_inputs(p, [], 1024)
  // Override `key` so the starts-with(u/) condition fails.
  let bad =
    pipeline.Inputs(
      ..inputs,
      fields: policy.build_field_map([
        #("key", "x/photo.png"),
        #("policy", p),
        #("x-amz-algorithm", "AWS4-HMAC-SHA256"),
        #("x-amz-credential", credential),
        #("x-amz-date", amz_date),
        #("x-amz-signature", sign(p)),
        #("file", ""),
      ]),
    )
  let assert Error(err) = pipeline.run(bad)
  assert errors.code(err.kind) == "AccessDenied"
}

pub fn bucket_mismatch_returns_access_denied_test() {
  let p = build_policy_b64("")
  let inputs = base_inputs(p, [], 1024)
  let mismatched = pipeline.Inputs(..inputs, bucket: "other-bucket")
  let assert Error(err) = pipeline.run(mismatched)
  assert errors.code(err.kind) == "AccessDenied"
}

pub fn content_length_range_violation_test() {
  let p = build_policy_b64("[\"content-length-range\",100,200]")
  let inputs = base_inputs(p, [], 50)
  let assert Error(err) = pipeline.run(inputs)
  assert errors.code(err.kind) == "AccessDenied"
}

pub fn file_size_above_max_returns_entity_too_large_test() {
  let p = build_policy_b64("")
  let inputs = base_inputs(p, [], 30_000_000)
  let assert Error(err) = pipeline.run(inputs)
  assert errors.code(err.kind) == "EntityTooLarge"
}

pub fn uncovered_field_rejected_test() {
  let p = build_policy_b64("")
  let inputs = base_inputs(p, [#("acl", "private")], 1024)
  let assert Error(err) = pipeline.run(inputs)
  assert errors.code(err.kind) == "AccessDenied"
}

pub fn condition_check_runs_before_signature_per_spec_test() {
  // Spec §7 puts conditions (step 7) before signature (step 8). With both a
  // bad condition AND a bad signature, the condition error must surface.
  let p = build_policy_b64("")
  let inputs = base_inputs(p, [], 1024)
  let bad =
    pipeline.Inputs(
      ..inputs,
      fields: policy.build_field_map([
        #("key", "x/photo.png"),
        #("policy", p),
        #("x-amz-algorithm", "AWS4-HMAC-SHA256"),
        #("x-amz-credential", credential),
        #("x-amz-date", amz_date),
        #("x-amz-signature", "0000000000"),
        #("file", ""),
      ]),
    )
  let assert Error(err) = pipeline.run(bad)
  assert errors.code(err.kind) == "AccessDenied"
}

pub fn covered_field_with_extra_eq_condition_test() {
  let p = build_policy_b64("{\"acl\":\"private\"}")
  let inputs = base_inputs(p, [#("acl", "private")], 1024)
  assert pipeline.run(inputs) != Error(errors.invalid_request("anything"))
  let assert Ok(_) = pipeline.run(inputs)
}
