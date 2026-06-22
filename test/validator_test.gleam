//// Strict policy validator (spec §10.5).

import gleam/dict
import repost/policy
import repost/validator

fn fields(pairs: List(#(String, String))) -> policy.FieldMap {
  policy.build_field_map(pairs)
}

pub fn happy_path_test() {
  let conditions = [
    policy.Eq(field: "bucket", value: "outline-uploads"),
    policy.StartsWith(field: "key", prefix: "user/eric/"),
    policy.Eq(field: "acl", value: "public-read"),
    policy.ContentLengthRange(min: 1, max: 1_000_000),
  ]
  let form =
    fields([
      #("bucket", "outline-uploads"),
      #("key", "user/eric/photo.png"),
      #("acl", "public-read"),
      #("file", ""),
      #("policy", "..."),
      #("x-amz-signature", "..."),
      #("x-amz-algorithm", "AWS4-HMAC-SHA256"),
      #("x-amz-credential", "..."),
      #("x-amz-date", "..."),
    ])
  assert validator.validate(conditions, form, 1024) == Ok(Nil)
}

pub fn exact_match_violation_test() {
  let conditions = [policy.Eq(field: "acl", value: "public-read")]
  let form = fields([#("acl", "private")])
  assert validator.validate(conditions, form, 0)
    == Error(validator.ConditionMismatch(field: "acl"))
}

pub fn prefix_violation_test() {
  let conditions = [policy.StartsWith(field: "key", prefix: "user/eric/")]
  let form = fields([#("key", "user/joe/photo.png")])
  assert validator.validate(conditions, form, 0)
    == Error(validator.ConditionMismatch(field: "key"))
}

pub fn range_violation_below_min_test() {
  let conditions = [policy.ContentLengthRange(min: 100, max: 1000)]
  assert validator.validate(conditions, dict.new(), 50)
    == Error(validator.LengthOutOfRange)
}

pub fn range_violation_above_max_test() {
  let conditions = [policy.ContentLengthRange(min: 100, max: 1000)]
  assert validator.validate(conditions, dict.new(), 5000)
    == Error(validator.LengthOutOfRange)
}

pub fn range_inclusive_endpoints_test() {
  let conditions = [policy.ContentLengthRange(min: 100, max: 1000)]
  assert validator.validate(conditions, dict.new(), 100) == Ok(Nil)
  assert validator.validate(conditions, dict.new(), 1000) == Ok(Nil)
}

pub fn uncovered_field_rejected_test() {
  let conditions = [policy.StartsWith(field: "key", prefix: "")]
  let form = fields([#("key", "anything"), #("acl", "private")])
  assert validator.validate(conditions, form, 0)
    == Error(validator.UncoveredField(field: "acl"))
}

pub fn exempt_fields_do_not_need_coverage_test() {
  let conditions = [policy.StartsWith(field: "key", prefix: "")]
  let form =
    fields([
      #("key", "x"),
      #("file", ""),
      #("policy", "..."),
      #("x-amz-signature", "..."),
      #("x-amz-algorithm", "AWS4-HMAC-SHA256"),
      #("x-amz-credential", "..."),
      #("x-amz-date", "..."),
      #("x-amz-security-token", "..."),
    ])
  assert validator.validate(conditions, form, 0) == Ok(Nil)
}

pub fn case_insensitive_field_matching_test() {
  let conditions = [policy.StartsWith(field: "Key", prefix: "user/")]
  let form = fields([#("Key", "user/x")])
  assert validator.validate(conditions, form, 0) == Ok(Nil)
}

pub fn case_sensitive_value_matching_test() {
  let conditions = [policy.Eq(field: "acl", value: "Public-Read")]
  let form = fields([#("acl", "public-read")])
  assert validator.validate(conditions, form, 0)
    == Error(validator.ConditionMismatch(field: "acl"))
}

pub fn empty_prefix_matches_any_value_test() {
  let conditions = [policy.StartsWith(field: "x-amz-meta-tag", prefix: "")]
  let form = fields([#("x-amz-meta-tag", "anything-goes-here")])
  assert validator.validate(conditions, form, 0) == Ok(Nil)
}

pub fn missing_field_from_eq_condition_test() {
  let conditions = [policy.Eq(field: "acl", value: "private")]
  assert validator.validate(conditions, dict.new(), 0)
    == Error(validator.ConditionMismatch(field: "acl"))
}
