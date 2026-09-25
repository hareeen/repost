//// Multipart event loop: collects text fields, validates, then pipes the
//// `file` part chunk-by-chunk to R2.

import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/http/response as http_response
import gleam/int
import gleam/list
import gleam/string
import mist

import repost/authorize
import repost/config.{type Config}
import repost/cors
import repost/errors.{type ErrorResponse}
import repost/multipart
import repost/r2
import repost/r2/put_object
import repost/server/response
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
  decision: cors.OriginDecision,
  bucket: String,
) -> http_response.Response(mist.ResponseData) {
  loop(
    parser,
    ProcessState(
      deps:,
      decision:,
      bucket:,
      fields: dict.new(),
      field_bytes_used: 0,
      field_count: 0,
      current_field: NoCurrentField,
      r2: NoR2,
      file_bytes_seen: 0,
      file_chunks: [],
    ),
  )
}

type CurrentField {
  NoCurrentField
  CollectingTextField(name: String, accumulated: BitArray)
  StreamingFile(name: String)
}

type R2State {
  NoR2
  R2Buffered(authorized: authorize.Authorized)
}

type ProcessState {
  ProcessState(
    deps: Deps,
    decision: cors.OriginDecision,
    bucket: String,
    fields: Dict(String, String),
    field_bytes_used: Int,
    field_count: Int,
    current_field: CurrentField,
    r2: R2State,
    file_bytes_seen: Int,
    file_chunks: List(BitArray),
  )
}

fn loop(
  parser: multipart.State,
  state: ProcessState,
) -> http_response.Response(mist.ResponseData) {
  case multipart.next_event(parser) {
    Error(parse_err) -> handle_parse_error(state, parse_err)
    Ok(#(event, next_parser)) -> handle_event(next_parser, state, event)
  }
}

fn handle_event(
  parser: multipart.State,
  state: ProcessState,
  event: multipart.Event,
) -> http_response.Response(mist.ResponseData) {
  case event {
    multipart.PartStart(name:, ..) -> handle_part_start(parser, state, name)
    multipart.PartChunk(bytes) -> handle_part_chunk(parser, state, bytes)
    multipart.PartEnd -> handle_part_end(parser, state)
    multipart.MessageEnd -> finalize(state)
  }
}

fn handle_part_start(
  parser: multipart.State,
  state: ProcessState,
  name: String,
) -> http_response.Response(mist.ResponseData) {
  case string.lowercase(name) == "file" {
    True -> begin_file_part(parser, state, name)
    False ->
      // Spec §6.2: file must be the last field. Close R2 first so the
      // socket isn't leaked.
      case state.r2 {
        R2Buffered(..) -> {
          response.xml_error(
            state.decision,
            errors.invalid_request(
              "multipart fields must precede the `file` part",
            ),
          )
        }
        NoR2 -> {
          // Names are retained as dict keys, so they count against the cap.
          let used = state.field_bytes_used + string.byte_size(name)
          let count = state.field_count + 1
          case used > text_fields_cap || count > max_text_fields {
            True ->
              response.xml_error(
                state.decision,
                errors.invalid_request("form fields exceeded soft cap"),
              )
            False ->
              loop(
                parser,
                ProcessState(
                  ..state,
                  field_bytes_used: used,
                  field_count: count,
                  current_field: CollectingTextField(name:, accumulated: <<>>),
                ),
              )
          }
        }
      }
  }
}

fn handle_part_chunk(
  parser: multipart.State,
  state: ProcessState,
  bytes: BitArray,
) -> http_response.Response(mist.ResponseData) {
  case state.current_field {
    StreamingFile(_) -> stream_to_r2(parser, state, bytes)
    CollectingTextField(name:, accumulated:) -> {
      let used = state.field_bytes_used + bit_array.byte_size(bytes)
      case used > text_fields_cap {
        True ->
          response.xml_error(
            state.decision,
            errors.invalid_request("form fields exceeded soft cap"),
          )
        False ->
          loop(
            parser,
            ProcessState(
              ..state,
              field_bytes_used: used,
              current_field: CollectingTextField(
                name:,
                accumulated: bit_array.append(accumulated, bytes),
              ),
            ),
          )
      }
    }
    NoCurrentField ->
      response.xml_error(
        state.decision,
        errors.invalid_request("malformed multipart"),
      )
  }
}

fn handle_part_end(
  parser: multipart.State,
  state: ProcessState,
) -> http_response.Response(mist.ResponseData) {
  case state.current_field {
    CollectingTextField(name:, accumulated:) ->
      case bit_array.to_string(accumulated) {
        Error(_) ->
          response.xml_error(
            state.decision,
            errors.invalid_request("non-UTF8 form field: " <> name),
          )
        Ok(value) ->
          loop(
            parser,
            ProcessState(
              ..state,
              current_field: NoCurrentField,
              fields: dict.insert(state.fields, name, value),
            ),
          )
      }
    StreamingFile(_) ->
      loop(parser, ProcessState(..state, current_field: NoCurrentField))
    NoCurrentField -> loop(parser, state)
  }
}

fn begin_file_part(
  parser: multipart.State,
  state: ProcessState,
  field_name: String,
) -> http_response.Response(mist.ResponseData) {
  case state.r2 {
    R2Buffered(..) -> {
      response.xml_error(
        state.decision,
        errors.invalid_request("more than one `file` field"),
      )
    }
    NoR2 ->
      case
        authorize.authorize(
          state.fields,
          state.bucket,
          state.deps.config,
          state.deps.clock(),
        )
      {
        Error(err) -> response.xml_error(state.decision, err)
        Ok(authorized) ->
          loop(
            parser,
            ProcessState(
              ..state,
              current_field: StreamingFile(name: field_name),
              r2: R2Buffered(authorized:),
            ),
          )
      }
  }
}

fn stream_to_r2(
  parser: multipart.State,
  state: ProcessState,
  bytes: BitArray,
) -> http_response.Response(mist.ResponseData) {
  case state.r2 {
    NoR2 ->
      response.xml_error(
        state.decision,
        errors.shim_error("stream-to-r2 without conn"),
      )
    R2Buffered(..) -> {
      let new_total = state.file_bytes_seen + bit_array.byte_size(bytes)
      // Spec §10.2.3: abort the moment the cumulative byte count exceeds
      // the bound.
      let upper = effective_upper_bound(state)
      case new_total > upper {
        True -> response.xml_error(state.decision, errors.entity_too_large())
        False ->
          loop(
            parser,
            ProcessState(..state, file_bytes_seen: new_total, file_chunks: [
              bytes,
              ..state.file_chunks
            ]),
          )
      }
    }
  }
}

fn finalize(state: ProcessState) -> http_response.Response(mist.ResponseData) {
  case state.r2 {
    NoR2 ->
      response.xml_error(
        state.decision,
        errors.invalid_request("missing `file` field"),
      )
    R2Buffered(authorized:) ->
      case check_lower_bound(state) {
        Error(err) -> response.xml_error(state.decision, err)
        Ok(_) ->
          put_buffered_to_r2(state, authorized.key, authorized.content_type)
      }
  }
}

fn put_buffered_to_r2(
  state: ProcessState,
  key: String,
  content_type: Result(String, Nil),
) -> http_response.Response(mist.ResponseData) {
  let body = bit_array.concat(list.reverse(state.file_chunks))
  case
    put_object.put_buffered(
      state.deps.endpoint,
      state.deps.config,
      key,
      content_type,
      state.deps.clock(),
      body,
    )
  {
    Error(err) -> response.xml_error(state.decision, err)
    Ok(resp) ->
      case resp.status >= 200 && resp.status < 300 {
        True ->
          response.success(state.decision, list.key_find(resp.headers, "etag"))
        False ->
          response.xml_error(
            state.decision,
            errors.internal_error(
              "R2 returned status " <> int.to_string(resp.status),
            ),
          )
      }
  }
}

fn effective_upper_bound(state: ProcessState) -> Int {
  let cfg_max = state.deps.config.max_upload_bytes
  case state.r2 {
    NoR2 -> cfg_max
    R2Buffered(authorized:) ->
      case authorized.length_bounds {
        authorize.LengthBounds(min: _, max:) -> int.min(max, cfg_max)
        authorize.NoLengthBounds -> cfg_max
      }
  }
}

fn check_lower_bound(state: ProcessState) -> Result(Nil, ErrorResponse) {
  case state.r2 {
    NoR2 -> Ok(Nil)
    R2Buffered(authorized:) ->
      case authorized.length_bounds {
        authorize.LengthBounds(min:, max: _) ->
          case state.file_bytes_seen >= min {
            True -> Ok(Nil)
            False ->
              Error(errors.access_denied(
                "file size outside content-length-range",
              ))
          }
        authorize.NoLengthBounds -> Ok(Nil)
      }
  }
}

fn handle_parse_error(
  state: ProcessState,
  err: multipart.ParseError,
) -> http_response.Response(mist.ResponseData) {
  case err {
    multipart.HeaderLimitExceeded ->
      response.xml_error(
        state.decision,
        errors.invalid_request("part header too large"),
      )
    multipart.ReadError(detail: _) ->
      response.xml_error(
        state.decision,
        errors.invalid_request("transport read failed"),
      )
    multipart.AfterMessageEnd ->
      response.xml_error(
        state.decision,
        errors.shim_error("parse stage corruption"),
      )
    _ ->
      response.xml_error(
        state.decision,
        errors.invalid_request("malformed multipart"),
      )
  }
}
