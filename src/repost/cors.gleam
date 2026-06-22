//// CORS allow-list and response-header construction (spec §6.1, §6.2).
//// Origins are matched verbatim against the configured allow-list.

import gleam/list

pub type OriginDecision {
  Allowed(origin: String)
  Denied
  NoOrigin
}

pub fn evaluate(
  origin_header: Result(String, Nil),
  allowed_origins: List(String),
) -> OriginDecision {
  case origin_header {
    Error(_) -> NoOrigin
    Ok(origin) ->
      case list.contains(allowed_origins, origin) {
        True -> Allowed(origin)
        False -> Denied
      }
  }
}

pub fn success_headers(origin: String) -> List(#(String, String)) {
  [
    #("access-control-allow-origin", origin),
    #("access-control-expose-headers", "ETag"),
    #("vary", "Origin"),
  ]
}

pub fn preflight_headers(origin: String) -> List(#(String, String)) {
  [
    #("access-control-allow-origin", origin),
    #("access-control-allow-methods", "POST"),
    #("access-control-allow-headers", "content-type, x-amz-*"),
    #("access-control-max-age", "3600"),
    #("vary", "Origin"),
  ]
}

pub fn error_headers(decision: OriginDecision) -> List(#(String, String)) {
  case decision {
    Allowed(origin) -> [
      #("access-control-allow-origin", origin),
      #("vary", "Origin"),
    ]
    _ -> []
  }
}
