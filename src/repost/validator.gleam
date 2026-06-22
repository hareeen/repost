//// Strict POST-policy validator (spec §10): every declared condition must
//// hold and every non-exempt form field must be covered by some condition.
//// Field comparison is case-insensitive; value comparison is case-sensitive.

import gleam/dict
import gleam/list
import gleam/set
import gleam/string

import repost/policy.{
  type Condition, type FieldMap, ContentLengthRange, Eq, StartsWith,
}

pub type ValidationError {
  ConditionMismatch(field: String)
  UncoveredField(field: String)
  LengthOutOfRange
}

pub const exempt_fields: List(String) = [
  "file", "policy", "x-amz-signature", "x-amz-algorithm", "x-amz-credential",
  "x-amz-date", "x-amz-security-token",
]

pub fn validate(
  conditions: List(Condition),
  form_fields: FieldMap,
  file_size: Int,
) -> Result(Nil, ValidationError) {
  case check_conditions(conditions, form_fields, file_size, set.new()) {
    Error(e) -> Error(e)
    Ok(covered) -> check_coverage(form_fields, covered)
  }
}

fn check_conditions(
  conditions: List(Condition),
  form_fields: FieldMap,
  file_size: Int,
  covered: set.Set(String),
) -> Result(set.Set(String), ValidationError) {
  case conditions {
    [] -> Ok(covered)
    [c, ..rest] ->
      case evaluate(c, form_fields, file_size) {
        Error(e) -> Error(e)
        Ok(field_covered) -> {
          let covered = case field_covered {
            Some(f) -> set.insert(covered, f)
            None -> covered
          }
          check_conditions(rest, form_fields, file_size, covered)
        }
      }
  }
}

type MaybeField {
  Some(String)
  None
}

fn evaluate(
  condition: Condition,
  form_fields: FieldMap,
  file_size: Int,
) -> Result(MaybeField, ValidationError) {
  case condition {
    Eq(field:, value:) -> {
      let key = string.lowercase(field)
      case dict.get(form_fields, key) {
        Ok(actual) if actual == value -> Ok(Some(key))
        _ -> Error(ConditionMismatch(field: key))
      }
    }
    StartsWith(field:, prefix:) -> {
      let key = string.lowercase(field)
      case dict.get(form_fields, key) {
        Ok(actual) ->
          case string.starts_with(actual, prefix) {
            True -> Ok(Some(key))
            False -> Error(ConditionMismatch(field: key))
          }
        Error(_) -> Error(ConditionMismatch(field: key))
      }
    }
    ContentLengthRange(min:, max:) ->
      case file_size >= min && file_size <= max {
        True -> Ok(None)
        False -> Error(LengthOutOfRange)
      }
  }
}

fn check_coverage(
  form_fields: FieldMap,
  covered: set.Set(String),
) -> Result(Nil, ValidationError) {
  let exempt = set.from_list(exempt_fields)
  let keys = dict.keys(form_fields)
  case
    list.find(keys, fn(k) {
      let key = string.lowercase(k)
      !set.contains(exempt, key) && !set.contains(covered, key)
    })
  {
    Ok(field) -> Error(UncoveredField(field:))
    Error(_) -> Ok(Nil)
  }
}
