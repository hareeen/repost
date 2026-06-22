//// CORS allow-list and header construction.

import repost/cors

pub fn allowed_origin_matches_exactly_test() {
  let allowed = ["https://outline.example.com", "https://other.example.org"]
  assert cors.evaluate(Ok("https://outline.example.com"), allowed)
    == cors.Allowed("https://outline.example.com")
}

pub fn denied_when_not_in_list_test() {
  let allowed = ["https://outline.example.com"]
  assert cors.evaluate(Ok("https://attacker.example.com"), allowed)
    == cors.Denied
}

pub fn missing_origin_test() {
  assert cors.evaluate(Error(Nil), ["https://outline.example.com"])
    == cors.NoOrigin
}

pub fn case_sensitive_match_test() {
  // Origins are byte-for-byte; uppercase host should not match lowercase
  // entry.
  let allowed = ["https://outline.example.com"]
  assert cors.evaluate(Ok("https://OUTLINE.example.com"), allowed)
    == cors.Denied
}

pub fn preflight_headers_present_test() {
  let h = cors.preflight_headers("https://outline.example.com")
  assert header(h, "access-control-allow-origin")
    == Ok("https://outline.example.com")
  assert header(h, "access-control-allow-methods") == Ok("POST")
  assert header(h, "access-control-allow-headers")
    == Ok("content-type, x-amz-*")
  assert header(h, "access-control-max-age") == Ok("3600")
  assert header(h, "vary") == Ok("Origin")
}

pub fn success_headers_expose_etag_test() {
  let h = cors.success_headers("https://outline.example.com")
  assert header(h, "access-control-expose-headers") == Ok("ETag")
  assert header(h, "vary") == Ok("Origin")
}

pub fn error_headers_only_when_allowed_test() {
  assert cors.error_headers(cors.Denied) == []
  assert cors.error_headers(cors.NoOrigin) == []
  let h = cors.error_headers(cors.Allowed("https://x"))
  assert header(h, "access-control-allow-origin") == Ok("https://x")
}

fn header(headers: List(#(String, String)), name: String) -> Result(String, Nil) {
  case headers {
    [] -> Error(Nil)
    [#(k, v), ..rest] ->
      case k == name {
        True -> Ok(v)
        False -> header(rest, name)
      }
  }
}
