//// Parse the multipart boundary out of a `Content-Type` header.

import gleam/list
import gleam/string

import repost/errors.{type ErrorResponse}

pub fn extract(content_type: String) -> Result(String, ErrorResponse) {
  case string.split(content_type, on: ";") {
    [] -> Error(errors.invalid_request("empty Content-Type"))
    [media, ..params] ->
      case string.lowercase(string.trim(media)) {
        "multipart/form-data" -> find_boundary(params)
        _ ->
          Error(errors.invalid_request(
            "expected Content-Type: multipart/form-data",
          ))
      }
  }
}

fn find_boundary(params: List(String)) -> Result(String, ErrorResponse) {
  case
    list.find_map(params, fn(p) {
      let trimmed = string.trim(p)
      case string.split_once(trimmed, "=") {
        Ok(#(name, value)) ->
          case string.lowercase(string.trim(name)) {
            "boundary" -> Ok(unquote(string.trim(value)))
            _ -> Error(Nil)
          }
        Error(_) -> Error(Nil)
      }
    })
  {
    Error(_) -> Error(errors.invalid_request("multipart boundary missing"))
    Ok("") -> Error(errors.invalid_request("multipart boundary empty"))
    Ok(b) -> Ok(b)
  }
}

/// Strip surrounding quotes only when both sides are present. A value with a
/// stray opening or closing quote is treated as unquoted — better to keep
/// the bytes than silently lose one.
fn unquote(value: String) -> String {
  case string.starts_with(value, "\"") && string.ends_with(value, "\"") {
    False -> value
    True -> {
      let len = string.length(value)
      case len >= 2 {
        True -> string.slice(value, at_index: 1, length: len - 2)
        False -> value
      }
    }
  }
}
