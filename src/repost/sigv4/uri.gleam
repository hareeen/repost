//// RFC 3986 percent-encoding for SigV4 canonical URIs.

import gleam/bit_array
import gleam/list
import gleam/string

pub fn encode_path(key: String) -> String {
  string.split(key, "/")
  |> list.map(encode_segment)
  |> string.join("/")
}

pub fn encode_segment(input: String) -> String {
  string.to_utf_codepoints(input)
  |> list.map(encode_codepoint)
  |> string.concat
}

fn encode_codepoint(cp: UtfCodepoint) -> String {
  let n = string.utf_codepoint_to_int(cp)
  case is_unreserved(n) {
    True -> string.from_utf_codepoints([cp])
    False -> percent_encode_codepoint(cp)
  }
}

fn is_unreserved(n: Int) -> Bool {
  case n {
    0x2D | 0x2E | 0x5F | 0x7E -> True
    _ ->
      { n >= 0x30 && n <= 0x39 }
      || { n >= 0x41 && n <= 0x5A }
      || { n >= 0x61 && n <= 0x7A }
  }
}

fn percent_encode_codepoint(cp: UtfCodepoint) -> String {
  let bits = bit_array.from_string(string.from_utf_codepoints([cp]))
  bytes_to_percent_hex(bits, "")
}

fn bytes_to_percent_hex(input: BitArray, acc: String) -> String {
  case input {
    <<>> -> acc
    <<byte, rest:bytes>> ->
      bytes_to_percent_hex(
        rest,
        acc <> "%" <> bit_array.base16_encode(<<byte>>),
      )
    _ -> acc
  }
}
