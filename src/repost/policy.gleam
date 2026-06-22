//// S3 POST policy decoder. Each condition is either a single-key object
//// (exact match), `["eq" | "starts-with", "$field", value]`, or
//// `["content-length-range", min, max]`.

import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/result
import gleam/string

pub type Condition {
  Eq(field: String, value: String)
  StartsWith(field: String, prefix: String)
  ContentLengthRange(min: Int, max: Int)
}

pub type Policy {
  Policy(expiration: String, conditions: List(Condition))
}

pub type DecodeFailure {
  Base64Decode
  NonUtf8
  JsonSyntax
  Schema(detail: String)
}

/// Field names lowercased to match AWS's case-insensitive comparison
/// (spec §10.2.4); values are preserved.
pub type FieldMap =
  Dict(String, String)

pub fn build_field_map(values: List(#(String, String))) -> FieldMap {
  values
  |> list.map(fn(p) {
    let #(k, v) = p
    #(string.lowercase(k), v)
  })
  |> dict.from_list
}

pub fn decode_policy(base64_policy: String) -> Result(Policy, DecodeFailure) {
  use raw <- result.try(
    bit_array.base64_decode(base64_policy)
    |> result.replace_error(Base64Decode),
  )
  use json_str <- result.try(
    bit_array.to_string(raw)
    |> result.replace_error(NonUtf8),
  )
  use parsed <- result.try(parse_json(json_str))
  decode_top(parsed)
}

fn parse_json(s: String) -> Result(Dynamic, DecodeFailure) {
  json.parse(from: s, using: decode.dynamic)
  |> result.replace_error(JsonSyntax)
}

fn decode_top(value: Dynamic) -> Result(Policy, DecodeFailure) {
  let decoder = {
    use expiration <- decode.field("expiration", decode.string)
    use conditions_dyn <- decode.field(
      "conditions",
      decode.list(decode.dynamic),
    )
    decode.success(#(expiration, conditions_dyn))
  }
  case decode.run(value, decoder) {
    Error(_) -> Error(Schema("expected {expiration, conditions}"))
    Ok(#(expiration, conditions_dyn)) -> {
      use conditions <- result.map(decode_conditions(conditions_dyn))
      Policy(expiration:, conditions:)
    }
  }
}

fn decode_conditions(
  raw: List(Dynamic),
) -> Result(List(Condition), DecodeFailure) {
  do_decode_conditions(raw, [])
}

fn do_decode_conditions(
  raw: List(Dynamic),
  acc: List(Condition),
) -> Result(List(Condition), DecodeFailure) {
  case raw {
    [] -> Ok(list.reverse(acc))
    [head, ..rest] -> {
      use c <- result.try(decode_condition(head))
      do_decode_conditions(rest, [c, ..acc])
    }
  }
}

fn decode_condition(value: Dynamic) -> Result(Condition, DecodeFailure) {
  // Try array form first; if that fails, fall back to single-pair object.
  case decode.run(value, decode.list(decode.dynamic)) {
    Ok(items) -> decode_array_condition(items)
    Error(_) -> decode_object_condition(value)
  }
}

fn decode_array_condition(
  items: List(Dynamic),
) -> Result(Condition, DecodeFailure) {
  case items {
    [op_d, a_d, b_d] -> {
      use op <- result.try(
        decode.run(op_d, decode.string)
        |> result.replace_error(Schema("condition op must be a string")),
      )
      case op {
        "eq" -> {
          use field <- result.try(decode_dollar_field(a_d))
          use val <- result.try(decode_string_value(b_d, "eq value"))
          Ok(Eq(field:, value: val))
        }
        "starts-with" -> {
          use field <- result.try(decode_dollar_field(a_d))
          use prefix <- result.try(decode_string_value(
            b_d,
            "starts-with prefix",
          ))
          Ok(StartsWith(field:, prefix:))
        }
        "content-length-range" -> {
          use min <- result.try(decode_int(a_d, "content-length-range min"))
          use max <- result.try(decode_int(b_d, "content-length-range max"))
          case min < 0 || max < min {
            True -> Error(Schema("invalid content-length-range bounds"))
            False -> Ok(ContentLengthRange(min:, max:))
          }
        }
        other -> Error(Schema("unknown condition operator: " <> other))
      }
    }
    _ -> Error(Schema("array condition must have exactly 3 elements"))
  }
}

fn decode_dollar_field(value: Dynamic) -> Result(String, DecodeFailure) {
  use raw <- result.try(decode_string_value(value, "field reference"))
  case string.starts_with(raw, "$") {
    True ->
      Ok(
        string.lowercase(string.slice(
          raw,
          at_index: 1,
          length: string.length(raw) - 1,
        )),
      )
    False -> Error(Schema("field reference must start with '$': " <> raw))
  }
}

fn decode_string_value(
  value: Dynamic,
  context: String,
) -> Result(String, DecodeFailure) {
  decode.run(value, decode.string)
  |> result.replace_error(Schema(context <> " must be a string"))
}

fn decode_int(value: Dynamic, context: String) -> Result(Int, DecodeFailure) {
  decode.run(value, decode.int)
  |> result.replace_error(Schema(context <> " must be an integer"))
}

fn decode_object_condition(value: Dynamic) -> Result(Condition, DecodeFailure) {
  case decode.run(value, decode.dict(decode.string, decode.string)) {
    Error(_) ->
      Error(Schema("condition must be {\"field\": \"value\"} or [op, ...]"))
    Ok(d) ->
      case dict.to_list(d) {
        [#(k, v)] -> Ok(Eq(field: string.lowercase(k), value: v))
        _ ->
          Error(Schema("object condition must have exactly one key/value pair"))
      }
  }
}
