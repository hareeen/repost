//// Multipart event loop: collects text fields, validates, then pipes the
//// `file` part chunk-by-chunk to R2.

import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/http/response as http_response
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import mist

import repost/config.{type Config}
import repost/cors
import repost/errors.{type ErrorResponse}
import repost/multipart_stream as ms
import repost/pipeline
import repost/policy
import repost/streaming/mist_response
import repost/streaming/r2_put
import repost/time

const text_fields_cap: Int = 1_048_576

pub type Clock =
  fn() -> Int

pub type Deps {
  Deps(config: Config, clock: Clock, endpoint: r2_put.Endpoint)
}

pub fn default_deps(config: Config) -> Deps {
  Deps(
    config:,
    clock: fn() { time.now_seconds_utc() },
    endpoint: r2_put.R2Endpoint(account_id: config.r2_account_id),
  )
}

pub fn run(
  parser: ms.State,
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
      current_field: NoCurrentField,
      r2: NoR2,
      file_bytes_seen: 0,
      file_chunks: [],
      policy_doc: NoPolicy,
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
  R2Buffered(key: String, content_type: Result(String, Nil))
}

type PolicySlot {
  NoPolicy
  HasPolicy(policy.Policy)
}

type ProcessState {
  ProcessState(
    deps: Deps,
    decision: cors.OriginDecision,
    bucket: String,
    fields: Dict(String, String),
    field_bytes_used: Int,
    current_field: CurrentField,
    r2: R2State,
    file_bytes_seen: Int,
    file_chunks: List(BitArray),
    policy_doc: PolicySlot,
  )
}

fn loop(
  parser: ms.State,
  state: ProcessState,
) -> http_response.Response(mist.ResponseData) {
  case ms.next_event(parser) {
    Error(parse_err) -> handle_parse_error(state, parse_err)
    Ok(#(event, next_parser)) -> handle_event(next_parser, state, event)
  }
}

fn handle_event(
  parser: ms.State,
  state: ProcessState,
  event: ms.Event,
) -> http_response.Response(mist.ResponseData) {
  case event {
    ms.PartStart(name:, ..) -> handle_part_start(parser, state, name)
    ms.PartChunk(bytes) -> handle_part_chunk(parser, state, bytes)
    ms.PartEnd -> handle_part_end(parser, state)
    ms.MessageEnd -> finalize(state)
  }
}

fn handle_part_start(
  parser: ms.State,
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
          mist_response.xml_error(
            state.decision,
            errors.invalid_request(
              "multipart fields must precede the `file` part",
            ),
          )
        }
        NoR2 ->
          loop(
            parser,
            ProcessState(
              ..state,
              current_field: CollectingTextField(name:, accumulated: <<>>),
            ),
          )
      }
  }
}

fn handle_part_chunk(
  parser: ms.State,
  state: ProcessState,
  bytes: BitArray,
) -> http_response.Response(mist.ResponseData) {
  case state.current_field {
    StreamingFile(_) -> stream_to_r2(parser, state, bytes)
    CollectingTextField(name:, accumulated:) -> {
      let used = state.field_bytes_used + bit_array.byte_size(bytes)
      case used > text_fields_cap {
        True ->
          mist_response.xml_error(
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
      mist_response.xml_error(
        state.decision,
        errors.invalid_request("malformed multipart"),
      )
  }
}

fn handle_part_end(
  parser: ms.State,
  state: ProcessState,
) -> http_response.Response(mist.ResponseData) {
  case state.current_field {
    CollectingTextField(name:, accumulated:) ->
      case bit_array.to_string(accumulated) {
        Error(_) ->
          mist_response.xml_error(
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
  parser: ms.State,
  state: ProcessState,
  field_name: String,
) -> http_response.Response(mist.ResponseData) {
  case state.r2 {
    R2Buffered(..) -> {
      mist_response.xml_error(
        state.decision,
        errors.invalid_request("more than one `file` field"),
      )
    }
    NoR2 ->
      case validate_pre_file(state) {
        Error(err) -> mist_response.xml_error(state.decision, err)
        Ok(#(policy_doc, key, content_type)) ->
          loop(
            parser,
            ProcessState(
              ..state,
              current_field: StreamingFile(name: field_name),
              r2: R2Buffered(key:, content_type:),
              policy_doc: HasPolicy(policy_doc),
            ),
          )
      }
  }
}

fn stream_to_r2(
  parser: ms.State,
  state: ProcessState,
  bytes: BitArray,
) -> http_response.Response(mist.ResponseData) {
  case state.r2 {
    NoR2 ->
      mist_response.xml_error(
        state.decision,
        errors.shim_error("stream-to-r2 without conn"),
      )
    R2Buffered(..) -> {
      let new_total = state.file_bytes_seen + bit_array.byte_size(bytes)
      // Spec §10.2.3: abort the moment the cumulative byte count exceeds
      // the bound.
      let upper = effective_upper_bound(state)
      case new_total > upper {
        True ->
          mist_response.xml_error(state.decision, errors.entity_too_large())
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
      mist_response.xml_error(
        state.decision,
        errors.invalid_request("missing `file` field"),
      )
    R2Buffered(key:, content_type:) ->
      case check_lower_bound(state) {
        Error(err) -> mist_response.xml_error(state.decision, err)
        Ok(_) -> put_buffered_to_r2(state, key, content_type)
      }
  }
}

fn put_buffered_to_r2(
  state: ProcessState,
  key: String,
  content_type: Result(String, Nil),
) -> http_response.Response(mist.ResponseData) {
  let body = concat_chunks(list.reverse(state.file_chunks), <<>>)
  case
    r2_put.put_buffered(
      state.deps.endpoint,
      state.deps.config,
      key,
      content_type,
      state.deps.clock(),
      body,
    )
  {
    Error(err) -> mist_response.xml_error(state.decision, err)
    Ok(resp) ->
      case resp.status >= 200 && resp.status < 300 {
        True ->
          mist_response.success(
            state.decision,
            list.key_find(resp.headers, "etag"),
          )
        False ->
          mist_response.xml_error(
            state.decision,
            errors.internal_error(
              "R2 returned status " <> int.to_string(resp.status),
            ),
          )
      }
  }
}

fn concat_chunks(chunks: List(BitArray), acc: BitArray) -> BitArray {
  case chunks {
    [] -> acc
    [chunk, ..rest] -> concat_chunks(rest, bit_array.append(acc, chunk))
  }
}

fn validate_pre_file(
  state: ProcessState,
) -> Result(#(policy.Policy, String, Result(String, Nil)), ErrorResponse) {
  let lowered = lowercase_keys(state.fields)
  use _ <- result.try(pipeline.check_required(lowered))
  use credential <- result.try(pipeline.check_credential(
    lowered,
    state.deps.config.shim_access_key_id,
    state.deps.config.shim_region,
  ))
  use policy_doc <- result.try(pipeline.check_policy(lowered))
  use _ <- result.try(pipeline.check_expiration(policy_doc, state.deps.clock()))
  use _ <- result.try(check_conditions_pre_size(
    lowered,
    state.bucket,
    policy_doc,
  ))
  use _ <- result.try(pipeline.check_signature(
    lowered,
    credential,
    state.deps.config.shim_secret_access_key,
  ))

  let key = case dict.get(lowered, "key") {
    Ok(k) -> k
    Error(_) -> ""
  }
  let content_type = dict.get(lowered, "content-type")
  Ok(#(policy_doc, key, content_type))
}

/// At this point file_size is unknown, so length conditions are enforced by
/// the streaming byte counter and final lower-bound check. All field
/// conditions still need to run before the R2 connection is opened.
fn check_conditions_pre_size(
  lowered: Dict(String, String),
  bucket: String,
  policy_doc: policy.Policy,
) -> Result(Nil, ErrorResponse) {
  let with_file = dict.insert(lowered, "file", "")
  let pre_size_policy =
    policy.Policy(
      ..policy_doc,
      conditions: without_length_conditions(policy_doc.conditions),
    )
  pipeline.check_conditions(with_file, bucket, 0, pre_size_policy)
}

fn without_length_conditions(
  conditions: List(policy.Condition),
) -> List(policy.Condition) {
  list.filter(conditions, fn(c) {
    case c {
      policy.ContentLengthRange(_, _) -> False
      _ -> True
    }
  })
}

fn effective_upper_bound(state: ProcessState) -> Int {
  let cfg_max = state.deps.config.max_upload_bytes
  case state.policy_doc {
    NoPolicy -> cfg_max
    HasPolicy(p) ->
      case pipeline.length_bounds(p) {
        pipeline.LengthBounds(min: _, max:) -> int_min(max, cfg_max)
        pipeline.NoLengthBounds -> cfg_max
      }
  }
}

fn check_lower_bound(state: ProcessState) -> Result(Nil, ErrorResponse) {
  case state.policy_doc {
    NoPolicy -> Ok(Nil)
    HasPolicy(p) ->
      case pipeline.length_bounds(p) {
        pipeline.LengthBounds(min:, max: _) ->
          case state.file_bytes_seen >= min {
            True -> Ok(Nil)
            False ->
              Error(errors.access_denied(
                "file size outside content-length-range",
              ))
          }
        pipeline.NoLengthBounds -> Ok(Nil)
      }
  }
}

fn handle_parse_error(
  state: ProcessState,
  err: ms.ParseError,
) -> http_response.Response(mist.ResponseData) {
  case err {
    ms.HeaderLimitExceeded ->
      mist_response.xml_error(
        state.decision,
        errors.invalid_request("part header too large"),
      )
    ms.ReadError(detail: _) ->
      mist_response.xml_error(
        state.decision,
        errors.invalid_request("transport read failed"),
      )
    ms.AfterMessageEnd ->
      mist_response.xml_error(
        state.decision,
        errors.shim_error("parse stage corruption"),
      )
    _ ->
      mist_response.xml_error(
        state.decision,
        errors.invalid_request("malformed multipart"),
      )
  }
}

fn lowercase_keys(d: Dict(String, String)) -> Dict(String, String) {
  d
  |> dict.to_list
  |> list.map(fn(p) { #(string.lowercase(p.0), p.1) })
  |> dict.from_list
}

fn int_min(a: Int, b: Int) -> Int {
  case a < b {
    True -> a
    False -> b
  }
}
