//// Multipart event loop: collects text fields, validates, then buffers the file for R2.

import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/string

import repost/authorize
import repost/config.{type Config}
import repost/errors.{type ErrorResponse}
import repost/multipart
import repost/r2
import repost/r2/put_object
import repost/time

const text_fields_cap: Int = 1_048_576

/// Text fields are buffered before the policy is checked, so without a count
/// cap an unauthenticated client could grow `fields` with endless parts.
const max_text_fields: Int = 64

pub type Clock =
  fn() -> Int

pub type Deps {
  Deps(config: Config, clock: Clock, endpoint: r2.Endpoint)
}

pub type Uploaded {
  Uploaded(etag: Result(String, Nil))
}

pub fn default_deps(config: Config) -> Deps {
  Deps(
    config:,
    clock: fn() { time.now_seconds_utc() },
    endpoint: r2.R2Endpoint(account_id: config.r2_account_id),
  )
}

pub fn run(
  parser: multipart.State,
  deps: Deps,
  bucket: String,
) -> Result(Uploaded, ErrorResponse) {
  loop(parser, deps, bucket, CollectingFields(dict.new(), 0, 0, NoCurrentField))
}

type CurrentField {
  NoCurrentField
  CollectingTextField(name: String, accumulated: BitArray)
}

type ProcessState {
  CollectingFields(
    fields: Dict(String, String),
    bytes_used: Int,
    count: Int,
    current: CurrentField,
  )
  ReceivingFile(
    authorized: authorize.Authorized,
    bytes_seen: Int,
    chunks: List(BitArray),
  )
}

fn loop(
  parser: multipart.State,
  deps: Deps,
  bucket: String,
  state: ProcessState,
) -> Result(Uploaded, ErrorResponse) {
  case multipart.next_event(parser) {
    Error(parse_err) -> Error(parse_error(parse_err))
    Ok(#(event, next_parser)) ->
      handle_event(next_parser, deps, bucket, state, event)
  }
}

fn handle_event(
  parser: multipart.State,
  deps: Deps,
  bucket: String,
  state: ProcessState,
  event: multipart.Event,
) -> Result(Uploaded, ErrorResponse) {
  case event {
    multipart.PartStart(name:, ..) ->
      handle_part_start(parser, deps, bucket, state, name)
    multipart.PartChunk(bytes) ->
      handle_part_chunk(parser, deps, bucket, state, bytes)
    multipart.PartEnd -> handle_part_end(parser, deps, bucket, state)
    multipart.MessageEnd -> finalize(deps, state)
  }
}

fn handle_part_start(
  parser: multipart.State,
  deps: Deps,
  bucket: String,
  state: ProcessState,
  name: String,
) -> Result(Uploaded, ErrorResponse) {
  case state, string.lowercase(name) == "file" {
    ReceivingFile(..), True ->
      Error(errors.invalid_request("more than one `file` field"))
    ReceivingFile(..), False ->
      Error(errors.invalid_request(
        "multipart fields must precede the `file` part",
      ))
    CollectingFields(fields:, ..), True ->
      case authorize.authorize(fields, bucket, deps.config, deps.clock()) {
        Error(err) -> Error(err)
        Ok(authorized) ->
          loop(parser, deps, bucket, ReceivingFile(authorized, 0, []))
      }
    CollectingFields(fields:, bytes_used:, count:, ..), False -> {
      // Names are retained as dict keys, so they count against the cap.
      let used = bytes_used + string.byte_size(name)
      let next_count = count + 1
      case used > text_fields_cap || next_count > max_text_fields {
        True -> Error(errors.invalid_request("form fields exceeded soft cap"))
        False ->
          loop(
            parser,
            deps,
            bucket,
            CollectingFields(
              fields,
              used,
              next_count,
              CollectingTextField(name, <<>>),
            ),
          )
      }
    }
  }
}

fn handle_part_chunk(
  parser: multipart.State,
  deps: Deps,
  bucket: String,
  state: ProcessState,
  bytes: BitArray,
) -> Result(Uploaded, ErrorResponse) {
  case state {
    ReceivingFile(authorized:, bytes_seen:, chunks:) -> {
      let new_total = bytes_seen + bit_array.byte_size(bytes)
      // Spec §10.2.3: abort the moment the cumulative byte count exceeds the bound.
      let upper = effective_upper_bound(deps, authorized)
      case new_total > upper {
        True -> Error(errors.entity_too_large())
        False ->
          loop(
            parser,
            deps,
            bucket,
            ReceivingFile(authorized, new_total, [bytes, ..chunks]),
          )
      }
    }
    CollectingFields(fields:, bytes_used:, count:, current:) ->
      case current {
        NoCurrentField -> Error(errors.invalid_request("malformed multipart"))
        CollectingTextField(name:, accumulated:) -> {
          let used = bytes_used + bit_array.byte_size(bytes)
          case used > text_fields_cap {
            True ->
              Error(errors.invalid_request("form fields exceeded soft cap"))
            False ->
              loop(
                parser,
                deps,
                bucket,
                CollectingFields(
                  fields,
                  used,
                  count,
                  CollectingTextField(
                    name,
                    bit_array.append(accumulated, bytes),
                  ),
                ),
              )
          }
        }
      }
  }
}

fn handle_part_end(
  parser: multipart.State,
  deps: Deps,
  bucket: String,
  state: ProcessState,
) -> Result(Uploaded, ErrorResponse) {
  case state {
    ReceivingFile(..) -> loop(parser, deps, bucket, state)
    CollectingFields(fields:, bytes_used:, count:, current:) ->
      case current {
        NoCurrentField -> loop(parser, deps, bucket, state)
        CollectingTextField(name:, accumulated:) ->
          case bit_array.to_string(accumulated) {
            Error(_) ->
              Error(errors.invalid_request("non-UTF8 form field: " <> name))
            Ok(value) ->
              loop(
                parser,
                deps,
                bucket,
                CollectingFields(
                  dict.insert(fields, name, value),
                  bytes_used,
                  count,
                  NoCurrentField,
                ),
              )
          }
      }
  }
}

fn finalize(
  deps: Deps,
  state: ProcessState,
) -> Result(Uploaded, ErrorResponse) {
  case state {
    CollectingFields(..) ->
      Error(errors.invalid_request("missing `file` field"))
    ReceivingFile(authorized:, bytes_seen:, chunks:) -> {
      case check_lower_bound(authorized, bytes_seen) {
        Error(err) -> Error(err)
        Ok(_) -> put_buffered_to_r2(deps, authorized, chunks)
      }
    }
  }
}

fn put_buffered_to_r2(
  deps: Deps,
  authorized: authorize.Authorized,
  chunks: List(BitArray),
) -> Result(Uploaded, ErrorResponse) {
  let body = bit_array.concat(list.reverse(chunks))
  case
    put_object.put_buffered(
      deps.endpoint,
      deps.config,
      authorized.key,
      authorized.content_type,
      deps.clock(),
      body,
    )
  {
    Error(err) -> Error(err)
    Ok(resp) -> Ok(Uploaded(list.key_find(resp.headers, "etag")))
  }
}

fn effective_upper_bound(deps: Deps, authorized: authorize.Authorized) -> Int {
  let cfg_max = deps.config.max_upload_bytes
  case authorized.length_bounds {
    authorize.LengthBounds(min: _, max:) -> int.min(max, cfg_max)
    authorize.NoLengthBounds -> cfg_max
  }
}

fn check_lower_bound(
  authorized: authorize.Authorized,
  bytes_seen: Int,
) -> Result(Nil, ErrorResponse) {
  case authorized.length_bounds {
    authorize.LengthBounds(min:, max: _) ->
      case bytes_seen >= min {
        True -> Ok(Nil)
        False ->
          Error(errors.access_denied("file size outside content-length-range"))
      }
    authorize.NoLengthBounds -> Ok(Nil)
  }
}

fn parse_error(err: multipart.ParseError) -> ErrorResponse {
  case err {
    multipart.HeaderLimitExceeded ->
      errors.invalid_request("part header too large")
    multipart.ReadError(detail: _) ->
      errors.invalid_request("transport read failed")
    multipart.AfterMessageEnd -> errors.shim_error("parse stage corruption")
    _ -> errors.invalid_request("malformed multipart")
  }
}
