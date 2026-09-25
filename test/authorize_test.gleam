import gleam/bit_array
import gleam/dict
import repost/authorize
import repost/config
import repost/errors
import repost/policy
import repost/sigv4

const shim_secret: String = "test-shim-secret"

const shim_ak: String = "shim-app-key"

const shim_region: String = "auto"

const date: String = "20240115"

const amz_date: String = "20240115T000000Z"

const credential: String = "shim-app-key/20240115/auto/s3/aws4_request"

const now: Int = 1_705_276_800

fn test_config() -> config.Config {
  config.Config(
    shim_access_key_id: shim_ak,
    shim_secret_access_key: shim_secret,
    shim_region: shim_region,
    r2_account_id: "fake",
    r2_access_key_id: "r2-key",
    r2_secret_access_key: "r2-secret",
    r2_bucket: "my-bucket",
    allowed_origins: [],
    max_upload_bytes: 26_214_400,
    shim_base_host: "",
    bind_interface: "127.0.0.1",
    port: 0,
  )
}

fn build_policy_b64(extra: String) -> String {
  let json =
    "{\"expiration\":\"2025-01-01T00:00:00Z\",\"conditions\":["
    <> "{\"bucket\":\"my-bucket\"},"
    <> "[\"starts-with\",\"$key\",\"u/\"]"
    <> extra
    <> "]}"
  bit_array.base64_encode(bit_array.from_string(json), True)
}

fn sign(policy_b64: String) -> String {
  let signing = sigv4.signing_key(shim_secret, date, shim_region, "s3")
  sigv4.hex(sigv4.hmac(bit_array.from_string(policy_b64), signing))
}

fn base_fields(
  policy_b64: String,
  extra: List(#(String, String)),
) -> policy.FieldMap {
  [
    #("key", "u/photo.png"),
    #("policy", policy_b64),
    #("x-amz-algorithm", "AWS4-HMAC-SHA256"),
    #("x-amz-credential", credential),
    #("x-amz-date", amz_date),
    #("x-amz-signature", sign(policy_b64)),
    ..extra
  ]
  |> dict.from_list
}

fn authorize_fields(
  fields: policy.FieldMap,
) -> Result(authorize.Authorized, errors.ErrorResponse) {
  authorize.authorize(fields, "my-bucket", test_config(), now)
}

pub fn happy_path_test() {
  let assert Ok(authorized) =
    authorize_fields(base_fields(build_policy_b64(""), []))
  assert authorized.key == "u/photo.png"
  assert authorized.content_type == Error(Nil)
  assert authorized.length_bounds == authorize.NoLengthBounds
}

pub fn missing_required_field_returns_invalid_request_test() {
  let fields = base_fields(build_policy_b64(""), []) |> dict.delete("key")
  let assert Error(err) = authorize_fields(fields)
  assert errors.code(err.kind) == "InvalidRequest"
}

pub fn empty_key_rejected_test() {
  let fields = base_fields(build_policy_b64(""), []) |> dict.insert("key", "")
  let assert Error(err) = authorize_fields(fields)
  assert errors.code(err.kind) == "InvalidRequest"
  assert err.message == "key must not be empty"
}

pub fn wrong_signature_test() {
  let fields =
    base_fields(build_policy_b64(""), [])
    |> dict.insert("x-amz-signature", "0000000000")
  let assert Error(err) = authorize_fields(fields)
  assert errors.code(err.kind) == "SignatureDoesNotMatch"
}

pub fn wrong_access_key_returns_signature_mismatch_test() {
  let bad_cred = "wrong-key/20240115/auto/s3/aws4_request"
  let fields =
    base_fields(build_policy_b64(""), [])
    |> dict.insert("x-amz-credential", bad_cred)
  let assert Error(err) = authorize_fields(fields)
  assert errors.code(err.kind) == "SignatureDoesNotMatch"
}

pub fn expired_policy_returns_access_denied_test() {
  let fields = base_fields(build_policy_b64(""), [])
  let assert Error(err) =
    authorize.authorize(fields, "my-bucket", test_config(), 9_999_999_999)
  assert errors.code(err.kind) == "AccessDenied"
}

pub fn condition_mismatch_returns_access_denied_test() {
  let fields =
    base_fields(build_policy_b64(""), []) |> dict.insert("key", "x/photo.png")
  let assert Error(err) = authorize_fields(fields)
  assert errors.code(err.kind) == "AccessDenied"
}

pub fn bucket_mismatch_returns_access_denied_test() {
  let fields = base_fields(build_policy_b64(""), [])
  let assert Error(err) =
    authorize.authorize(fields, "other-bucket", test_config(), now)
  assert errors.code(err.kind) == "AccessDenied"
  assert err.message == "policy bucket mismatch"
}

pub fn content_length_range_bounds_test() {
  let fields =
    base_fields(build_policy_b64(",[\"content-length-range\",100,200]"), [])
  let assert Ok(authorized) = authorize_fields(fields)
  assert authorized.length_bounds == authorize.LengthBounds(min: 100, max: 200)
}

pub fn max_upload_bytes_remains_available_to_upload_test() {
  let assert Ok(authorized) =
    authorize_fields(base_fields(build_policy_b64(""), []))
  assert authorized.length_bounds == authorize.NoLengthBounds
  assert test_config().max_upload_bytes == 26_214_400
}

pub fn uncovered_field_rejected_test() {
  let fields = base_fields(build_policy_b64(""), [#("acl", "private")])
  let assert Error(err) = authorize_fields(fields)
  assert errors.code(err.kind) == "AccessDenied"
}

pub fn condition_check_runs_before_signature_per_spec_test() {
  let fields = base_fields(build_policy_b64(""), [])
  let fields = dict.insert(fields, "key", "x/photo.png")
  let fields = dict.insert(fields, "x-amz-signature", "0000000000")
  let assert Error(err) = authorize_fields(fields)
  assert errors.code(err.kind) == "AccessDenied"
}

pub fn covered_field_with_extra_eq_condition_test() {
  let fields =
    base_fields(build_policy_b64(",{\"acl\":\"private\"}"), [
      #("acl", "private"),
    ])
  let assert Ok(_) = authorize_fields(fields)
}

pub fn content_type_lookup_is_case_insensitive_test() {
  let fields =
    base_fields(
      build_policy_b64(",[\"starts-with\",\"$Content-Type\",\"image/\"]"),
      [],
    )
  let fields = dict.insert(fields, "Content-Type", "image/png")
  let assert Ok(authorized) = authorize_fields(fields)
  assert authorized.content_type == Ok("image/png")
}
