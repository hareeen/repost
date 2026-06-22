//// XML error response shape.

import gleam/string
import repost/errors

pub fn signature_mismatch_status_and_code_test() {
  let e = errors.signature_mismatch()
  assert errors.status(e.kind) == 403
  assert errors.code(e.kind) == "SignatureDoesNotMatch"
}

pub fn access_denied_status_and_code_test() {
  let e = errors.access_denied("policy expired")
  assert errors.status(e.kind) == 403
  assert errors.code(e.kind) == "AccessDenied"
}

pub fn invalid_request_status_and_code_test() {
  let e = errors.invalid_request("missing key")
  assert errors.status(e.kind) == 400
  assert errors.code(e.kind) == "InvalidRequest"
}

pub fn entity_too_large_status_and_code_test() {
  let e = errors.entity_too_large()
  assert errors.status(e.kind) == 400
  assert errors.code(e.kind) == "EntityTooLarge"
}

pub fn internal_error_status_and_code_test() {
  let e = errors.internal_error("R2 returned 502")
  assert errors.status(e.kind) == 502
  assert errors.code(e.kind) == "InternalError"
}

pub fn xml_body_format_test() {
  let body = errors.to_xml(errors.access_denied("policy expired"))
  assert string.contains(body, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>")
  assert string.contains(body, "<Code>AccessDenied</Code>")
  assert string.contains(body, "<Message>policy expired</Message>")
}

pub fn xml_escapes_special_characters_test() {
  let body = errors.to_xml(errors.invalid_request("a < b & c > d"))
  assert string.contains(body, "<Message>a &lt; b &amp; c &gt; d</Message>")
}
