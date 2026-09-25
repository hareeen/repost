import gleam/bit_array
import gleam/http
import gleam/http/response
import gleam/int
import gleam/list
import gleam/result
import gleam/string

import repost/r2
import repost/sigv4
import repost/xml

pub opaque type UploadId {
  UploadId(String)
}

pub opaque type PartNumber {
  PartNumber(Int)
}

pub type PartEtag {
  PartEtag(number: PartNumber, etag: String)
}

pub type PartNumberError {
  PartNumberOutOfRange(Int)
}

pub type MultipartError {
  SendFailed(r2.R2Error)
  ResponseNotUtf8
  MalformedResponse(xml.XmlError)
  MissingEtag
  CompleteError(code: String)
}

pub fn part_number(number: Int) -> Result(PartNumber, PartNumberError) {
  case number >= 1 && number <= 10_000 {
    True -> Ok(PartNumber(number))
    False -> Error(PartNumberOutOfRange(number))
  }
}

pub fn create(
  endpoint: r2.Endpoint,
  creds: sigv4.SigningCredentials,
  bucket: String,
  key: String,
  content_type: Result(String, Nil),
  now: Int,
) -> Result(UploadId, MultipartError) {
  use reply <- result.try(send(
    endpoint,
    creds,
    http.Post,
    bucket,
    key,
    [#("uploads", "")],
    // Content-Type on Create sets the stored object's metadata.
    case content_type {
      Ok(value) -> [#("content-type", value)]
      Error(_) -> []
    },
    <<>>,
    now,
  ))
  use body <- result.try(decode_body(reply.body))
  xml.element_text(body, "UploadId")
  |> result.map(UploadId)
  |> result.map_error(MalformedResponse)
}

pub fn upload_part(
  endpoint: r2.Endpoint,
  creds: sigv4.SigningCredentials,
  bucket: String,
  key: String,
  id: UploadId,
  number: PartNumber,
  body: BitArray,
  now: Int,
) -> Result(PartEtag, MultipartError) {
  let UploadId(upload_id) = id
  let PartNumber(part_number) = number
  use reply <- result.try(send(
    endpoint,
    creds,
    http.Put,
    bucket,
    key,
    [#("partNumber", int.to_string(part_number)), #("uploadId", upload_id)],
    [],
    body,
    now,
  ))
  response.get_header(reply, "etag")
  |> result.map(fn(etag) { PartEtag(number, etag) })
  |> result.map_error(fn(_) { MissingEtag })
}

pub fn complete(
  endpoint: r2.Endpoint,
  creds: sigv4.SigningCredentials,
  bucket: String,
  key: String,
  id: UploadId,
  parts: List(PartEtag),
  now: Int,
) -> Result(String, MultipartError) {
  let UploadId(upload_id) = id
  let encoded_parts =
    parts
    |> list.sort(by: fn(a, b) {
      int.compare(part_number_value(a.number), part_number_value(b.number))
    })
    |> list.map(fn(part) {
      "<Part><PartNumber>"
      <> int.to_string(part_number_value(part.number))
      <> "</PartNumber><ETag>"
      <> xml.escape(part.etag)
      <> "</ETag></Part>"
    })
    |> string.concat
  let body =
    "<CompleteMultipartUpload>" <> encoded_parts <> "</CompleteMultipartUpload>"
  use reply <- result.try(send(
    endpoint,
    creds,
    http.Post,
    bucket,
    key,
    [#("uploadId", upload_id)],
    [#("content-type", "application/xml")],
    bit_array.from_string(body),
    now,
  ))
  use response_body <- result.try(decode_body(reply.body))
  case xml.error_code(response_body) {
    Ok(code) -> Error(CompleteError(code))
    Error(_) ->
      xml.element_text(response_body, "ETag")
      |> result.map_error(MalformedResponse)
  }
}

pub fn abort(
  endpoint: r2.Endpoint,
  creds: sigv4.SigningCredentials,
  bucket: String,
  key: String,
  id: UploadId,
  now: Int,
) -> Result(Nil, MultipartError) {
  let UploadId(upload_id) = id
  send(
    endpoint,
    creds,
    http.Delete,
    bucket,
    key,
    [#("uploadId", upload_id)],
    [],
    <<>>,
    now,
  )
  |> result.map(fn(_) { Nil })
}

fn part_number_value(number: PartNumber) -> Int {
  let PartNumber(value) = number
  value
}

fn send(
  endpoint: r2.Endpoint,
  creds: sigv4.SigningCredentials,
  method: http.Method,
  bucket: String,
  key: String,
  query: List(#(String, String)),
  headers: List(#(String, String)),
  body: BitArray,
  now: Int,
) -> Result(response.Response(BitArray), MultipartError) {
  r2.send(endpoint, creds, method, bucket, key, query, headers, body, now)
  |> result.map_error(SendFailed)
}

fn decode_body(body: BitArray) -> Result(String, MultipartError) {
  bit_array.to_string(body) |> result.map_error(fn(_) { ResponseNotUtf8 })
}
