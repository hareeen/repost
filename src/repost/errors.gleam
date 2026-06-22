//// S3-style XML error responses (`<Code>` and `<Message>` only — spec §6.3).

import gleam/string

pub type ErrorKind {
  SignatureDoesNotMatch
  AccessDenied
  InvalidRequest
  EntityTooLarge
  /// 502 — R2 upstream rejected or could not be contacted.
  InternalError
  /// 500 — failure on the shim itself; surfaces the same "InternalError"
  /// code so operator dashboards can split it from upstream failures.
  ShimError
  NoSuchBucket
  MethodNotAllowed
}

pub type ErrorResponse {
  ErrorResponse(kind: ErrorKind, message: String)
}

pub fn signature_mismatch() -> ErrorResponse {
  ErrorResponse(
    SignatureDoesNotMatch,
    "The request signature we calculated does not match the signature you provided.",
  )
}

pub fn access_denied(detail: String) -> ErrorResponse {
  ErrorResponse(AccessDenied, detail)
}

pub fn invalid_request(detail: String) -> ErrorResponse {
  ErrorResponse(InvalidRequest, detail)
}

pub fn entity_too_large() -> ErrorResponse {
  ErrorResponse(
    EntityTooLarge,
    "Your proposed upload exceeds the maximum allowed size.",
  )
}

pub fn internal_error(detail: String) -> ErrorResponse {
  ErrorResponse(InternalError, detail)
}

pub fn shim_error(detail: String) -> ErrorResponse {
  ErrorResponse(ShimError, detail)
}

pub fn no_such_bucket() -> ErrorResponse {
  ErrorResponse(NoSuchBucket, "The specified bucket does not exist.")
}

pub fn method_not_allowed() -> ErrorResponse {
  ErrorResponse(
    MethodNotAllowed,
    "The specified method is not allowed against this resource.",
  )
}

pub fn status(kind: ErrorKind) -> Int {
  case kind {
    SignatureDoesNotMatch -> 403
    AccessDenied -> 403
    InvalidRequest -> 400
    EntityTooLarge -> 400
    InternalError -> 502
    ShimError -> 500
    NoSuchBucket -> 404
    MethodNotAllowed -> 405
  }
}

pub fn code(kind: ErrorKind) -> String {
  case kind {
    SignatureDoesNotMatch -> "SignatureDoesNotMatch"
    AccessDenied -> "AccessDenied"
    InvalidRequest -> "InvalidRequest"
    EntityTooLarge -> "EntityTooLarge"
    InternalError -> "InternalError"
    ShimError -> "InternalError"
    NoSuchBucket -> "NoSuchBucket"
    MethodNotAllowed -> "MethodNotAllowed"
  }
}

pub fn to_xml(error: ErrorResponse) -> String {
  let ErrorResponse(kind, message) = error
  "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<Error><Code>"
  <> code(kind)
  <> "</Code><Message>"
  <> escape_xml(message)
  <> "</Message></Error>"
}

fn escape_xml(input: String) -> String {
  input
  |> string.replace("&", "&amp;")
  |> string.replace("<", "&lt;")
  |> string.replace(">", "&gt;")
  |> string.replace("\"", "&quot;")
  |> string.replace("'", "&apos;")
}
