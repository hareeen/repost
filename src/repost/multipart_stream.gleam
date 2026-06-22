//// Streaming multipart/form-data parser. Each call to `next_event` yields
//// the next event without buffering the part body in memory.

import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/http
import gleam/list
import gleam/result
import gleam/string

pub type ChunkResult {
  ReaderEof
  ReaderChunk(data: BitArray, next: Reader)
  ReaderError(detail: String)
}

pub type Reader =
  fn() -> ChunkResult

pub type Event {
  PartStart(
    name: String,
    filename: Result(String, Nil),
    content_type: Result(String, Nil),
    headers: Dict(String, String),
  )
  PartChunk(BitArray)
  PartEnd
  MessageEnd
}

pub type ParseError {
  ReadError(detail: String)
  Malformed
  PrematureEof
  HeaderLimitExceeded
  /// Returned when the caller advances past `MessageEnd`.
  AfterMessageEnd
}

pub opaque type State {
  State(
    reader: Reader,
    boundary: String,
    buffer: BitArray,
    stage: Stage,
    pending_body: PendingBody,
    pending_headers: PendingHeaders,
    queued: List(Event),
    header_cap: Int,
    header_pulled: Int,
  )
}

type Stage {
  ExpectingPartHeaders
  InPartBody(
    name: String,
    ct: Result(String, Nil),
    filename: Result(String, Nil),
  )
  AtMessageEnd
  AfterMessageEndConsumed
}

type PendingBody {
  NoBodyContinuation
  BodyContinuation(fn(BitArray) -> Result(http.MultipartBody, Nil))
}

type PendingHeaders {
  NoHeaderContinuation
  HeaderContinuation(fn(BitArray) -> Result(http.MultipartHeaders, Nil))
}

/// Bytes scanned per part-header before we give up. Bounds adversarial
/// inputs that would otherwise trigger unbounded reads.
pub const default_header_buffer_cap: Int = 65_536

pub fn new(reader: Reader, boundary: String) -> State {
  State(
    reader:,
    boundary:,
    buffer: <<>>,
    stage: ExpectingPartHeaders,
    pending_body: NoBodyContinuation,
    pending_headers: NoHeaderContinuation,
    queued: [],
    header_cap: default_header_buffer_cap,
    header_pulled: 0,
  )
}

pub fn with_header_cap(state: State, cap: Int) -> State {
  State(..state, header_cap: cap)
}

pub fn next_event(state: State) -> Result(#(Event, State), ParseError) {
  case state.queued {
    [event, ..rest] -> Ok(#(event, State(..state, queued: rest)))
    [] -> drive(state)
  }
}

fn drive(state: State) -> Result(#(Event, State), ParseError) {
  case state.stage {
    AfterMessageEndConsumed -> Error(AfterMessageEnd)
    AtMessageEnd ->
      Ok(#(MessageEnd, State(..state, stage: AfterMessageEndConsumed)))
    ExpectingPartHeaders -> drive_headers(state)
    InPartBody(_, _, _) -> drive_body(state)
  }
}

fn drive_headers(state: State) -> Result(#(Event, State), ParseError) {
  case state.pending_headers {
    HeaderContinuation(cont) -> step_headers_via_continuation(state, cont)
    NoHeaderContinuation -> {
      // `parse_multipart_headers` on an empty buffer falls into the
      // preamble-skipper, which would silently consume the first boundary as
      // preamble and drop the first part. Make sure we have enough bytes to
      // disambiguate before calling it.
      use prepared <- result.try(prefill_buffer(state))
      case http.parse_multipart_headers(prepared.buffer, prepared.boundary) {
        Error(_) -> Error(Malformed)
        Ok(parsed) -> handle_header_result(prepared, parsed)
      }
    }
  }
}

fn prefill_buffer(state: State) -> Result(State, ParseError) {
  let min_bytes = 2 + string.byte_size(state.boundary)
  prefill_loop(state, min_bytes)
}

fn prefill_loop(state: State, min_bytes: Int) -> Result(State, ParseError) {
  case bit_array.byte_size(state.buffer) >= min_bytes {
    True -> Ok(state)
    False ->
      case state.reader() {
        ReaderError(detail:) -> Error(ReadError(detail:))
        ReaderEof -> Ok(state)
        ReaderChunk(data:, next:) ->
          prefill_loop(
            State(
              ..state,
              buffer: bit_array.append(state.buffer, data),
              reader: next,
            ),
            min_bytes,
          )
      }
  }
}

fn step_headers_via_continuation(
  state: State,
  cont: fn(BitArray) -> Result(http.MultipartHeaders, Nil),
) -> Result(#(Event, State), ParseError) {
  use #(more, advanced) <- result.try(pull_more(state))
  case more {
    <<>> -> Error(PrematureEof)
    _ ->
      case cont(more) {
        Error(_) -> Error(Malformed)
        Ok(parsed) ->
          handle_header_result(
            State(..advanced, pending_headers: NoHeaderContinuation),
            parsed,
          )
      }
  }
}

fn handle_header_result(
  state: State,
  parsed: http.MultipartHeaders,
) -> Result(#(Event, State), ParseError) {
  case parsed {
    http.MoreRequiredForHeaders(continuation) -> {
      case state.header_pulled > state.header_cap {
        True -> Error(HeaderLimitExceeded)
        False -> {
          use #(more, advanced) <- result.try(pull_more(state))
          case more {
            <<>> -> Error(PrematureEof)
            _ ->
              case continuation(more) {
                Error(_) -> Error(Malformed)
                Ok(next_parsed) ->
                  handle_header_result(
                    State(
                      ..advanced,
                      pending_headers: HeaderContinuation(continuation),
                      header_pulled: advanced.header_pulled
                        + bit_array.byte_size(more),
                    ),
                    next_parsed,
                  )
              }
          }
        }
      }
    }

    http.MultipartHeaders(headers: [], remaining: _) ->
      Ok(#(
        MessageEnd,
        State(..state, stage: AfterMessageEndConsumed, buffer: <<>>),
      ))

    http.MultipartHeaders(headers:, remaining:) -> {
      let map = headers_to_dict(headers)
      case disposition(map) {
        Error(e) -> Error(e)
        Ok(#(name, filename)) -> {
          let ct = dict.get(map, "content-type")
          let new_state =
            State(
              ..state,
              buffer: remaining,
              stage: InPartBody(name:, ct:, filename:),
              pending_headers: NoHeaderContinuation,
              pending_body: NoBodyContinuation,
              header_pulled: 0,
            )
          Ok(#(
            PartStart(name:, filename:, content_type: ct, headers: map),
            new_state,
          ))
        }
      }
    }
  }
}

fn headers_to_dict(headers: List(#(String, String))) -> Dict(String, String) {
  list.map(headers, fn(h) { #(string.lowercase(h.0), h.1) })
  |> dict.from_list
}

fn disposition(
  headers: Dict(String, String),
) -> Result(#(String, Result(String, Nil)), ParseError) {
  case dict.get(headers, "content-disposition") {
    Error(_) -> Error(Malformed)
    Ok(raw) ->
      case http.parse_content_disposition(raw) {
        Error(_) -> Error(Malformed)
        Ok(http.ContentDisposition(_kind, parameters)) -> {
          let params =
            list.map(parameters, fn(p) { #(string.lowercase(p.0), p.1) })
          case list.key_find(params, "name") {
            Error(_) -> Error(Malformed)
            Ok(name) -> Ok(#(name, list.key_find(params, "filename")))
          }
        }
      }
  }
}

fn drive_body(state: State) -> Result(#(Event, State), ParseError) {
  case state.pending_body {
    BodyContinuation(cont) -> step_body_via_continuation(state, cont)
    NoBodyContinuation ->
      case http.parse_multipart_body(state.buffer, state.boundary) {
        Error(_) -> Error(Malformed)
        Ok(parsed) -> handle_body_result(state, parsed)
      }
  }
}

fn step_body_via_continuation(
  state: State,
  cont: fn(BitArray) -> Result(http.MultipartBody, Nil),
) -> Result(#(Event, State), ParseError) {
  use #(more, advanced) <- result.try(pull_more(state))
  case more {
    <<>> -> Error(PrematureEof)
    _ ->
      case cont(more) {
        Error(_) -> Error(Malformed)
        Ok(parsed) ->
          handle_body_result(
            State(..advanced, pending_body: NoBodyContinuation),
            parsed,
          )
      }
  }
}

fn handle_body_result(
  state: State,
  parsed: http.MultipartBody,
) -> Result(#(Event, State), ParseError) {
  case parsed {
    http.MoreRequiredForBody(chunk:, continuation:) -> {
      let next_state =
        State(
          ..state,
          buffer: <<>>,
          pending_body: BodyContinuation(continuation),
        )
      case bit_array.byte_size(chunk) {
        0 -> drive_body(next_state)
        _ -> Ok(#(PartChunk(chunk), next_state))
      }
    }

    http.MultipartBody(chunk:, done:, remaining:) -> {
      let after_part_end = case done {
        True -> AtMessageEnd
        False -> ExpectingPartHeaders
      }
      let base =
        State(
          ..state,
          stage: after_part_end,
          buffer: remaining,
          pending_body: NoBodyContinuation,
        )
      case bit_array.byte_size(chunk) {
        0 -> Ok(#(PartEnd, base))
        _ ->
          Ok(#(
            PartChunk(chunk),
            State(..base, queued: list.append(base.queued, [PartEnd])),
          ))
      }
    }
  }
}

fn pull_more(state: State) -> Result(#(BitArray, State), ParseError) {
  case state.reader() {
    ReaderEof -> Ok(#(<<>>, state))
    ReaderError(detail:) -> Error(ReadError(detail:))
    ReaderChunk(data:, next:) -> Ok(#(data, State(..state, reader: next)))
  }
}
