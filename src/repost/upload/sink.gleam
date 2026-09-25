import gleam/bit_array
import gleam/list
import gleam/result

import repost/config.{type Config}
import repost/errors.{type ErrorResponse}
import repost/r2.{type Endpoint}
import repost/r2/multipart_upload as multipart
import repost/r2/put_object

pub opaque type Sink {
  Sink(
    endpoint: Endpoint,
    config: Config,
    key: String,
    content_type: Result(String, Nil),
    clock: fn() -> Int,
    part_size: Int,
    state: State,
  )
}

type State {
  Aborted
  Pending(buffer: List(BitArray), size: Int)
  Multipart(
    id: multipart.UploadId,
    next_number: Int,
    parts: List(multipart.PartEtag),
    buffer: List(BitArray),
    size: Int,
  )
}

pub fn new(
  endpoint: Endpoint,
  config: Config,
  key: String,
  content_type: Result(String, Nil),
  clock: fn() -> Int,
  part_size: Int,
) -> Sink {
  Sink(endpoint, config, key, content_type, clock, part_size, Pending([], 0))
}

pub fn push(
  sink: Sink,
  chunk: BitArray,
) -> Result(Sink, #(Sink, ErrorResponse)) {
  let Sink(endpoint, config, key, content_type, clock, part_size, state) = sink
  let size = bit_array.byte_size(chunk)
  let state = case state {
    Aborted -> Aborted
    Pending(buffer, count) -> Pending([chunk, ..buffer], count + size)
    Multipart(id, next, parts, buffer, count) ->
      Multipart(id, next, parts, [chunk, ..buffer], count + size)
  }
  drain(Sink(endpoint, config, key, content_type, clock, part_size, state))
}

fn drain(sink: Sink) -> Result(Sink, #(Sink, ErrorResponse)) {
  let Sink(endpoint, config, key, content_type, clock, part_size, state) = sink
  case state {
    Aborted -> Error(#(sink, errors.shim_error("upload sink already aborted")))
    // Holding exactly one part lets an exactly-part-sized file finish as one PUT.
    Pending(_, size) if size <= part_size -> Ok(sink)
    Pending(buffer, size) -> {
      let creds = r2.credentials(config)
      case
        multipart.create(
          endpoint,
          creds,
          config.r2_bucket,
          key,
          content_type,
          clock(),
        )
      {
        Error(err) ->
          Error(#(sink, multipart_error("CreateMultipartUpload", err)))
        Ok(id) ->
          drain(Sink(
            endpoint,
            config,
            key,
            content_type,
            clock,
            part_size,
            Multipart(id, 1, [], buffer, size),
          ))
      }
    }
    Multipart(_, _, _, _, size) if size < part_size -> Ok(sink)
    Multipart(id, next, parts, buffer, size) -> {
      let all = bit_array.concat(list.reverse(buffer))
      let assert Ok(part) = bit_array.slice(all, 0, part_size)
      let assert Ok(rest) = bit_array.slice(all, part_size, size - part_size)
      case send_part(sink, id, next, part) {
        Error(err) -> Error(#(sink, err))
        Ok(uploaded) ->
          drain(Sink(
            endpoint,
            config,
            key,
            content_type,
            clock,
            part_size,
            Multipart(
              id,
              next + 1,
              [uploaded, ..parts],
              [copy(rest)],
              size - part_size,
            ),
          ))
      }
    }
  }
}

pub fn finish(
  sink: Sink,
) -> Result(Result(String, Nil), #(Sink, ErrorResponse)) {
  let Sink(endpoint, config, key, content_type, clock, _, state) = sink
  case state {
    Aborted -> Error(#(sink, errors.shim_error("upload sink already aborted")))
    Pending(buffer, _) ->
      case
        put_object.put_buffered(
          endpoint,
          config,
          key,
          content_type,
          clock(),
          bit_array.concat(list.reverse(buffer)),
        )
      {
        Error(err) -> Error(#(sink, err))
        Ok(reply) -> Ok(list.key_find(reply.headers, "etag"))
      }
    Multipart(id, next, parts, buffer, size) -> {
      let tail = bit_array.concat(list.reverse(buffer))
      let parts_result = case size {
        0 -> Ok(parts)
        _ ->
          send_part(sink, id, next, tail)
          |> result.map(fn(part) { [part, ..parts] })
      }
      case parts_result {
        Error(err) -> Error(#(sink, err))
        Ok(all_parts) ->
          case
            multipart.complete(
              endpoint,
              r2.credentials(config),
              config.r2_bucket,
              key,
              id,
              list.reverse(all_parts),
              clock(),
            )
          {
            Error(err) ->
              Error(#(sink, multipart_error("CompleteMultipartUpload", err)))
            Ok(etag) -> Ok(Ok(etag))
          }
      }
    }
  }
}

pub fn abort(sink: Sink, original: ErrorResponse) -> #(Sink, ErrorResponse) {
  let Sink(endpoint, config, key, content_type, clock, part_size, state) = sink
  let aborted =
    Sink(endpoint, config, key, content_type, clock, part_size, Aborted)
  case state {
    Aborted | Pending(..) -> #(aborted, original)
    Multipart(id, ..) ->
      case
        multipart.abort(
          endpoint,
          r2.credentials(config),
          config.r2_bucket,
          key,
          id,
          clock(),
        )
      {
        Ok(_) -> #(aborted, original)
        Error(_) -> {
          let errors.ErrorResponse(kind, message) = original
          #(
            aborted,
            errors.ErrorResponse(kind, message <> "; abort of upload failed"),
          )
        }
      }
  }
}

fn send_part(
  sink: Sink,
  id: multipart.UploadId,
  number: Int,
  body: BitArray,
) -> Result(multipart.PartEtag, ErrorResponse) {
  let Sink(endpoint, config, key, _, clock, _, _) = sink
  case multipart.part_number(number) {
    Error(_) ->
      Error(errors.internal_error("R2 UploadPart exceeded part number limit"))
    Ok(part_number) ->
      multipart.upload_part(
        endpoint,
        r2.credentials(config),
        config.r2_bucket,
        key,
        id,
        part_number,
        body,
        clock(),
      )
      |> result.map_error(fn(err) { multipart_error("UploadPart", err) })
  }
}

fn multipart_error(
  operation: String,
  err: multipart.MultipartError,
) -> ErrorResponse {
  let detail = case err {
    multipart.CompleteError(code) -> " returned " <> code
    _ -> " failed"
  }
  errors.internal_error("R2 " <> operation <> detail)
}

/// `rest` is a slice of the joined buffer, so without a copy it keeps that whole buffer (up to two parts) alive until the next flush.
@external(erlang, "binary", "copy")
fn copy(bytes: BitArray) -> BitArray
