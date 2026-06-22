//// Path-style and virtual-host bucket extraction (spec §6, §9). When
//// `shim_base_host` is empty, virtual-host routing is disabled.

import gleam/list
import gleam/string

pub type Route {
  BucketRoute(bucket: String, remainder: List(String))
  NoRoute
}

pub fn route(
  host_header: Result(String, Nil),
  path_segments: List(String),
  shim_base_host: String,
) -> Route {
  let host = case host_header {
    Ok(h) -> strip_port(string.lowercase(string.trim(h)))
    Error(_) -> ""
  }
  let base = string.lowercase(shim_base_host)

  case base, host {
    "", _ -> path_route(path_segments)
    _, h if h == base -> path_route(path_segments)
    _, _ ->
      case strip_suffix(host, "." <> base) {
        Ok(bucket) ->
          case is_valid_bucket(bucket) {
            True -> BucketRoute(bucket, path_segments)
            False -> NoRoute
          }
        Error(_) -> NoRoute
      }
  }
}

fn path_route(segments: List(String)) -> Route {
  case segments {
    [] -> NoRoute
    [bucket, ..rest] ->
      case is_valid_bucket(bucket) {
        True -> BucketRoute(bucket, rest)
        False -> NoRoute
      }
  }
}

fn strip_port(host: String) -> String {
  case string.split_once(host, ":") {
    Ok(#(h, _)) -> h
    Error(_) -> host
  }
}

fn strip_suffix(input: String, suffix: String) -> Result(String, Nil) {
  case string.ends_with(input, suffix) {
    False -> Error(Nil)
    True -> {
      let prefix_len = string.length(input) - string.length(suffix)
      Ok(string.slice(input, at_index: 0, length: prefix_len))
    }
  }
}

/// Conservative S3-style filter: 3..63 lowercase alnum/`-`/`.`, no leading
/// or trailing `-`/`.`, no `..`, no `/`. Refuses path-traversal fragments
/// and IP-shaped strings.
pub fn is_valid_bucket(name: String) -> Bool {
  let len = string.length(name)
  case
    len >= 3
    && len <= 63
    && !string.starts_with(name, "-")
    && !string.starts_with(name, ".")
    && !string.ends_with(name, "-")
    && !string.ends_with(name, ".")
    && !string.contains(name, "..")
    && !string.contains(name, "/")
  {
    False -> False
    True ->
      string.to_graphemes(name)
      |> list.all(is_bucket_char)
  }
}

fn is_bucket_char(c: String) -> Bool {
  case c {
    "-" | "." -> True
    _ -> is_lowercase_alnum(c)
  }
}

fn is_lowercase_alnum(c: String) -> Bool {
  case c {
    "a" | "b" | "c" | "d" | "e" | "f" | "g" | "h" | "i" | "j" -> True
    "k" | "l" | "m" | "n" | "o" | "p" | "q" | "r" | "s" | "t" -> True
    "u" | "v" | "w" | "x" | "y" | "z" -> True
    "0" | "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" -> True
    _ -> False
  }
}
