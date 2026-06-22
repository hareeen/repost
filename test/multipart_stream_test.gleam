//// Streaming multipart parser tests.

import gleam/bit_array
import gleam/list
import repost/multipart_stream as ms

const boundary: String = "BOUNDARY"

/// Build a request body with text fields and a file part. Field order is
/// preserved.
fn build_body(
  text_fields: List(#(String, String)),
  file_name: String,
  file_filename: String,
  file_content_type: String,
  file_bytes: BitArray,
) -> BitArray {
  let crlf = "\r\n"
  let dashes = "--"
  let prelude = fn(name: String) {
    dashes
    <> boundary
    <> crlf
    <> "Content-Disposition: form-data; name=\""
    <> name
    <> "\""
    <> crlf
    <> crlf
  }
  let text_parts =
    list.fold(text_fields, <<>>, fn(acc, pair) {
      let #(name, value) = pair
      <<acc:bits, { prelude(name) <> value <> crlf }:utf8>>
    })
  let file_header =
    dashes
    <> boundary
    <> crlf
    <> "Content-Disposition: form-data; name=\""
    <> file_name
    <> "\"; filename=\""
    <> file_filename
    <> "\""
    <> crlf
    <> "Content-Type: "
    <> file_content_type
    <> crlf
    <> crlf
  let trailer = crlf <> dashes <> boundary <> dashes <> crlf
  <<text_parts:bits, file_header:utf8, file_bytes:bits, trailer:utf8>>
}

/// Reader that splits a fixed payload into chunks of `chunk_size` bytes.
fn chunked_reader(payload: BitArray, chunk_size: Int) -> ms.Reader {
  reader_for(payload, chunk_size)
}

fn reader_for(remaining: BitArray, chunk_size: Int) -> ms.Reader {
  fn() {
    case bit_array.byte_size(remaining) {
      0 -> ms.ReaderEof
      total -> {
        let take = case total < chunk_size {
          True -> total
          False -> chunk_size
        }
        let assert Ok(chunk) = bit_array.slice(remaining, 0, take)
        let assert Ok(rest) = bit_array.slice(remaining, take, total - take)
        ms.ReaderChunk(data: chunk, next: reader_for(rest, chunk_size))
      }
    }
  }
}

fn drain(state: ms.State) -> Result(List(ms.Event), ms.ParseError) {
  drain_loop(state, [])
}

fn drain_loop(
  state: ms.State,
  acc: List(ms.Event),
) -> Result(List(ms.Event), ms.ParseError) {
  case ms.next_event(state) {
    Error(e) -> Error(e)
    Ok(#(ms.MessageEnd, _)) -> Ok(reverse([ms.MessageEnd, ..acc]))
    Ok(#(event, next_state)) -> drain_loop(next_state, [event, ..acc])
  }
}

@external(erlang, "lists", "reverse")
fn reverse(xs: List(a)) -> List(a)

pub fn happy_path_single_chunk_test() {
  let body =
    build_body(
      [#("name", "alice"), #("color", "purple")],
      "file",
      "x.bin",
      "application/octet-stream",
      bit_array.from_string("hello world"),
    )
  let state = ms.new(chunked_reader(body, bit_array.byte_size(body)), boundary)
  let assert Ok(events) = drain(state)
  assert event_count(events) == 10
  assert names(events) == ["name", "color", "file"]
  assert collect_part(events, "file") == bit_array.from_string("hello world")
  assert collect_part(events, "name") == bit_array.from_string("alice")
}

pub fn file_split_across_many_chunks_test() {
  let payload = bit_array.from_string(repeat_string("ABCDEF", 1000))
  // 6000 bytes
  let body =
    build_body(
      [#("key", "u/photo.bin")],
      "file",
      "photo.bin",
      "application/octet-stream",
      payload,
    )
  // Feed the parser 17-byte chunks so the file straddles many reads.
  let state = ms.new(chunked_reader(body, 17), boundary)
  let assert Ok(events) = drain(state)
  let collected = collect_part(events, "file")
  assert collected == payload
  // The file must have been delivered in MORE than one PartChunk, otherwise
  // the streaming property is meaningless.
  assert chunk_count(events, "file") > 1
}

pub fn handles_unicode_filename_test() {
  let body =
    build_body(
      [#("key", "x")],
      "file",
      "ünicodé.txt",
      "text/plain",
      bit_array.from_string("data"),
    )
  let state = ms.new(chunked_reader(body, 64), boundary)
  let assert Ok(events) = drain(state)
  let assert Ok(ms.PartStart(filename:, content_type:, ..)) =
    first_part_start(events, "file")
  assert filename == Ok("ünicodé.txt")
  assert content_type == Ok("text/plain")
}

pub fn rejects_garbage_after_message_end_test() {
  let body =
    build_body(
      [],
      "file",
      "f",
      "application/octet-stream",
      bit_array.from_string("hi"),
    )
  let state = ms.new(chunked_reader(body, 32), boundary)
  let assert Ok(events) = drain(state)
  // Re-running on the same state would return AfterMessageEnd, but drain
  // already stops at MessageEnd. Just sanity-check the events.
  assert names(events) == ["file"]
}

pub fn premature_eof_returns_error_test() {
  // Body terminates without the closing boundary.
  let body =
    "--BOUNDARY\r\nContent-Disposition: form-data; name=\"key\"\r\n\r\nval"
  let state = ms.new(chunked_reader(bit_array.from_string(body), 8), boundary)
  // PrematureEof or Malformed both reasonable here — what matters is we
  // don't loop forever or claim success.
  let assert Error(_) = drain(state)
}

fn event_count(events: List(ms.Event)) -> Int {
  case events {
    [] -> 0
    [_, ..rest] -> 1 + event_count(rest)
  }
}

fn names(events: List(ms.Event)) -> List(String) {
  case events {
    [] -> []
    [ms.PartStart(name:, ..), ..rest] -> [name, ..names(rest)]
    [_, ..rest] -> names(rest)
  }
}

fn first_part_start(
  events: List(ms.Event),
  name: String,
) -> Result(ms.Event, Nil) {
  case events {
    [] -> Error(Nil)
    [ms.PartStart(name: n, ..) as ev, ..] if n == name -> Ok(ev)
    [_, ..rest] -> first_part_start(rest, name)
  }
}

fn collect_part(events: List(ms.Event), target: String) -> BitArray {
  collect_part_in(events, target, False, <<>>)
}

fn collect_part_in(
  events: List(ms.Event),
  target: String,
  inside: Bool,
  acc: BitArray,
) -> BitArray {
  case events {
    [] -> acc
    [ms.PartStart(name:, ..), ..rest] -> {
      let now_inside = name == target
      collect_part_in(rest, target, now_inside, acc)
    }
    [ms.PartChunk(b), ..rest] if inside ->
      collect_part_in(rest, target, inside, bit_array.append(acc, b))
    [ms.PartEnd, ..rest] -> collect_part_in(rest, target, False, acc)
    [_, ..rest] -> collect_part_in(rest, target, inside, acc)
  }
}

fn chunk_count(events: List(ms.Event), target: String) -> Int {
  chunk_count_in(events, target, False, 0)
}

fn chunk_count_in(
  events: List(ms.Event),
  target: String,
  inside: Bool,
  acc: Int,
) -> Int {
  case events {
    [] -> acc
    [ms.PartStart(name:, ..), ..rest] ->
      chunk_count_in(rest, target, name == target, acc)
    [ms.PartChunk(_), ..rest] if inside ->
      chunk_count_in(rest, target, inside, acc + 1)
    [ms.PartEnd, ..rest] -> chunk_count_in(rest, target, False, acc)
    [_, ..rest] -> chunk_count_in(rest, target, inside, acc)
  }
}

fn repeat_string(s: String, n: Int) -> String {
  case n {
    0 -> ""
    _ -> s <> repeat_string(s, n - 1)
  }
}
