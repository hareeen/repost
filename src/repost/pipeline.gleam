//// Validation pipeline (spec §7). `run/1` runs every step against a
//// collected `Inputs`; the per-step functions exist so the streaming handler
//// can enforce some checks before the file body has been read.

import gleam/dict
import gleam/list
import gleam/result
import gleam/string

import repost/errors.{type ErrorResponse}
import repost/policy.{type Condition, type FieldMap, type Policy}
import repost/sigv4
import repost/time
import repost/validator

pub type Inputs {
  Inputs(
    bucket: String,
    /// Lowercased field name → value, with the `file` field excluded (its
    /// size lives in `file_size`).
    fields: FieldMap,
    /// Case-preserved values, retained for the case-insensitive
    /// `Content-Type` lookup we forward to R2.
    raw_values: List(#(String, String)),
    file_size: Int,
    now_seconds: Int,
    shim_access_key_id: String,
    shim_secret_access_key: String,
    shim_region: String,
    max_upload_bytes: Int,
  )
}

pub type ValidatedRequest {
  ValidatedRequest(
    bucket: String,
    key: String,
    content_type: Result(String, Nil),
  )
}

pub fn run(inputs: Inputs) -> Result(ValidatedRequest, ErrorResponse) {
  // Spec §7 order: required → algorithm → credential → policy → expiration
  // → conditions → signature → size.
  use _ <- result.try(check_required(inputs.fields))
  use credential <- result.try(check_credential(
    inputs.fields,
    inputs.shim_access_key_id,
    inputs.shim_region,
  ))
  use policy_doc <- result.try(check_policy(inputs.fields))
  use _ <- result.try(check_expiration(policy_doc, inputs.now_seconds))
  use _ <- result.try(check_conditions(
    inputs.fields,
    inputs.bucket,
    inputs.file_size,
    policy_doc,
  ))
  use _ <- result.try(check_signature(
    inputs.fields,
    credential,
    inputs.shim_secret_access_key,
  ))
  use _ <- result.try(check_size(inputs.file_size, inputs.max_upload_bytes))

  let key = required_field(inputs.fields, "key")
  let content_type = lookup_form_value(inputs.raw_values, "content-type")
  Ok(ValidatedRequest(bucket: inputs.bucket, key:, content_type:))
}

pub fn check_required(fields: FieldMap) -> Result(Nil, ErrorResponse) {
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

pub fn check_credential(
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

pub fn check_policy(fields: FieldMap) -> Result(Policy, ErrorResponse) {
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

pub fn check_expiration(
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

pub fn check_signature(
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

pub fn check_conditions(
  fields: FieldMap,
  bucket: String,
  file_size: Int,
  policy_doc: Policy,
) -> Result(Nil, ErrorResponse) {
  use _ <- result.try(check_bucket_condition(policy_doc.conditions, bucket))

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

pub fn check_bucket_condition(
  conditions: List(Condition),
  bucket: String,
) -> Result(Nil, ErrorResponse) {
  case
    list.find(conditions, fn(c) {
      case c {
        policy.Eq(field:, value: _) -> field == "bucket"
        _ -> False
      }
    })
  {
    Error(_) -> Ok(Nil)
    Ok(policy.Eq(field: _, value:)) ->
      case value == bucket {
        True -> Ok(Nil)
        False -> Error(errors.access_denied("policy bucket mismatch"))
      }
    Ok(_) -> Ok(Nil)
  }
}

pub fn check_size(
  file_size: Int,
  max_upload_bytes: Int,
) -> Result(Nil, ErrorResponse) {
  case file_size > max_upload_bytes {
    True -> Error(errors.entity_too_large())
    False -> Ok(Nil)
  }
}

pub type LengthBounds {
  NoLengthBounds
  LengthBounds(min: Int, max: Int)
}

pub fn length_bounds(policy_doc: Policy) -> LengthBounds {
  list.fold(policy_doc.conditions, NoLengthBounds, fn(bounds, condition) {
    case condition, bounds {
      policy.ContentLengthRange(min:, max:), NoLengthBounds ->
        LengthBounds(min:, max:)
      policy.ContentLengthRange(min:, max:),
        LengthBounds(min: old_min, max: old_max)
      -> LengthBounds(min: int_max(old_min, min), max: int_min(old_max, max))
      _, _ -> bounds
    }
  })
}

fn int_min(a: Int, b: Int) -> Int {
  case a < b {
    True -> a
    False -> b
  }
}

fn int_max(a: Int, b: Int) -> Int {
  case a > b {
    True -> a
    False -> b
  }
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

fn lookup_form_value(
  raw_values: List(#(String, String)),
  lowercased_name: String,
) -> Result(String, Nil) {
  case raw_values {
    [] -> Error(Nil)
    [#(k, v), ..rest] ->
      case string.lowercase(k) == lowercased_name {
        True -> Ok(v)
        False -> lookup_form_value(rest, lowercased_name)
      }
  }
}
