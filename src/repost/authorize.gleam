//// Validates upload fields before the file body is read.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/result
import gleam/string

import repost/config.{type Config}
import repost/errors.{type ErrorResponse}
import repost/policy.{type Condition, type FieldMap, type Policy}
import repost/policy/validator
import repost/sigv4
import repost/time

pub type Authorized {
  Authorized(
    key: String,
    content_type: Result(String, Nil),
    length_bounds: LengthBounds,
  )
}

pub fn authorize(
  fields: Dict(String, String),
  bucket: String,
  config: Config,
  now: Int,
) -> Result(Authorized, ErrorResponse) {
  let lowered = lowercase_keys(fields)
  use _ <- result.try(check_required(lowered))
  use key <- result.try(check_key(lowered))
  use credential <- result.try(check_credential(
    lowered,
    config.shim_access_key_id,
    config.shim_region,
  ))
  use policy_doc <- result.try(check_policy(lowered))
  use _ <- result.try(check_expiration(policy_doc, now))
  use _ <- result.try(check_conditions_pre_size(lowered, bucket, policy_doc))
  use _ <- result.try(check_signature(
    lowered,
    credential,
    config.shim_secret_access_key,
  ))
  let content_type = dict.get(lowered, "content-type")
  Ok(Authorized(key:, content_type:, length_bounds: length_bounds(policy_doc)))
}

fn check_required(fields: FieldMap) -> Result(Nil, ErrorResponse) {
  let needed = [
    "key", "policy", "x-amz-algorithm", "x-amz-credential", "x-amz-date",
    "x-amz-signature",
  ]
  case list.find(needed, fn(f) { !dict.has_key(fields, f) }) {
    Ok(missing) ->
      Error(errors.invalid_request("missing required field: " <> missing))
    Error(_) -> Ok(Nil)
  }
}

/// An empty key would turn the R2 PUT into a bucket-level request.
fn check_key(fields: FieldMap) -> Result(String, ErrorResponse) {
  case required_field(fields, "key") {
    "" -> Error(errors.invalid_request("key must not be empty"))
    key -> Ok(key)
  }
}

fn check_credential(
  fields: FieldMap,
  shim_access_key_id: String,
  shim_region: String,
) -> Result(sigv4.Credential, ErrorResponse) {
  use algo <- result.try(require(fields, "x-amz-algorithm"))
  use _ <- result.try(reject_unless(
    algo == "AWS4-HMAC-SHA256",
    errors.invalid_request("x-amz-algorithm must be AWS4-HMAC-SHA256"),
  ))
  use credential_raw <- result.try(require(fields, "x-amz-credential"))
  use amz_date <- result.try(require(fields, "x-amz-date"))
  use cred <- result.try(case sigv4.parse_credential(credential_raw) {
    Error(_) -> Error(errors.invalid_request("malformed x-amz-credential"))
    Ok(cred) -> Ok(cred)
  })
  let date_prefix = string.slice(amz_date, at_index: 0, length: 8)
  use _ <- result.try(reject_unless(
    cred.access_key == shim_access_key_id,
    errors.signature_mismatch(),
  ))
  use _ <- result.try(reject_unless(
    cred.region == shim_region,
    errors.signature_mismatch(),
  ))
  use _ <- result.try(reject_unless(
    cred.service == "s3",
    errors.signature_mismatch(),
  ))
  use _ <- result.try(reject_unless(
    cred.date == date_prefix,
    errors.signature_mismatch(),
  ))
  Ok(cred)
}

fn check_policy(fields: FieldMap) -> Result(Policy, ErrorResponse) {
  let raw = required_field(fields, "policy")
  case policy.decode_policy(raw) {
    Ok(p) -> Ok(p)
    Error(policy.Base64Decode) ->
      Error(errors.invalid_request("policy: invalid base64"))
    Error(policy.NonUtf8) ->
      Error(errors.invalid_request("policy: not valid UTF-8"))
    Error(policy.JsonSyntax) ->
      Error(errors.invalid_request("policy: invalid JSON"))
    Error(policy.Schema(detail)) ->
      Error(errors.invalid_request("policy: " <> detail))
  }
}

fn check_expiration(
  policy_doc: Policy,
  now_seconds: Int,
) -> Result(Nil, ErrorResponse) {
  case time.parse_iso8601_utc(policy_doc.expiration) {
    Error(_) ->
      Error(errors.invalid_request(
        "policy: expiration must be an ISO 8601 timestamp",
      ))
    Ok(expiry) ->
      case expiry > now_seconds {
        True -> Ok(Nil)
        False -> Error(errors.access_denied("policy expired"))
      }
  }
}

fn check_signature(
  fields: FieldMap,
  credential: sigv4.Credential,
  shim_secret: String,
) -> Result(Nil, ErrorResponse) {
  let policy_b64 = required_field(fields, "policy")
  let provided = required_field(fields, "x-amz-signature")
  case
    sigv4.verify_post_signature(
      policy_b64,
      provided,
      shim_secret,
      credential.date,
      credential.region,
    )
  {
    Ok(Nil) -> Ok(Nil)
    Error(_) -> Error(errors.signature_mismatch())
  }
}

fn check_conditions(
  fields: FieldMap,
  bucket: String,
  file_size: Int,
  policy_doc: Policy,
) -> Result(Nil, ErrorResponse) {
  let with_bucket = dict.insert(fields, "bucket", bucket)
  case validator.validate(policy_doc.conditions, with_bucket, file_size) {
    Ok(Nil) -> Ok(Nil)
    Error(validator.ConditionMismatch(field:)) ->
      Error(errors.access_denied("policy condition failed for field: " <> field))
    Error(validator.UncoveredField(field:)) ->
      Error(errors.access_denied("form field not covered by policy: " <> field))
    Error(validator.LengthOutOfRange) ->
      Error(errors.access_denied("file size outside content-length-range"))
  }
}

pub type LengthBounds {
  NoLengthBounds
  LengthBounds(min: Int, max: Int)
}

fn length_bounds(policy_doc: Policy) -> LengthBounds {
  list.fold(policy_doc.conditions, NoLengthBounds, fn(bounds, condition) {
    case condition, bounds {
      policy.ContentLengthRange(min:, max:), NoLengthBounds ->
        LengthBounds(min:, max:)
      policy.ContentLengthRange(min:, max:),
        LengthBounds(min: old_min, max: old_max)
      -> LengthBounds(min: int.max(old_min, min), max: int.min(old_max, max))
      _, _ -> bounds
    }
  })
}

fn check_conditions_pre_size(
  fields: FieldMap,
  bucket: String,
  policy_doc: Policy,
) -> Result(Nil, ErrorResponse) {
  // File length is checked while reading; every other condition is checked here.
  let with_file = dict.insert(fields, "file", "")
  let pre_size_policy =
    policy.Policy(
      ..policy_doc,
      conditions: without_length_conditions(policy_doc.conditions),
    )
  check_conditions(with_file, bucket, 0, pre_size_policy)
}

fn without_length_conditions(conditions: List(Condition)) -> List(Condition) {
  list.filter(conditions, fn(condition) {
    case condition {
      policy.ContentLengthRange(_, _) -> False
      _ -> True
    }
  })
}

fn lowercase_keys(fields: Dict(String, String)) -> FieldMap {
  fields
  |> dict.to_list
  |> list.map(fn(pair) { #(string.lowercase(pair.0), pair.1) })
  |> dict.from_list
}

fn required_field(fields: FieldMap, name: String) -> String {
  case dict.get(fields, name) {
    Ok(v) -> v
    Error(_) -> ""
  }
}

fn require(fields: FieldMap, name: String) -> Result(String, ErrorResponse) {
  case dict.get(fields, name) {
    Ok(v) -> Ok(v)
    Error(_) ->
      Error(errors.invalid_request("missing required field: " <> name))
  }
}

fn reject_unless(
  condition: Bool,
  err: ErrorResponse,
) -> Result(Nil, ErrorResponse) {
  case condition {
    True -> Ok(Nil)
    False -> Error(err)
  }
}
