//// Wall-clock helpers. Injected into validation/signing so tests can pin
//// the clock.

import gleam/int
import gleam/string
import gleam/time/calendar
import gleam/time/duration
import gleam/time/timestamp

pub type ParseError {
  Malformed
}

pub fn now_seconds_utc() -> Int {
  let #(seconds, _) =
    timestamp.to_unix_seconds_and_nanoseconds(timestamp.system_time())
  seconds
}

pub fn parse_iso8601_utc(s: String) -> Result(Int, ParseError) {
  case timestamp.parse_rfc3339(s) {
    Error(_) -> Error(Malformed)
    Ok(ts) -> {
      let #(seconds, _) = timestamp.to_unix_seconds_and_nanoseconds(ts)
      Ok(seconds)
    }
  }
}

/// Returns `YYYYMMDDTHHMMSSZ` (the SigV4 `x-amz-date` format).
pub fn format_amz_date(seconds: Int) -> String {
  let ts = timestamp.from_unix_seconds(seconds)
  let #(date, time) = timestamp.to_calendar(ts, duration.seconds(0))
  let calendar.Date(year:, month:, day:) = date
  let calendar.TimeOfDay(hours:, minutes:, seconds:, ..) = time
  pad4(year)
  <> pad2(calendar.month_to_int(month))
  <> pad2(day)
  <> "T"
  <> pad2(hours)
  <> pad2(minutes)
  <> pad2(seconds)
  <> "Z"
}

fn pad2(n: Int) -> String {
  case n < 10 {
    True -> "0" <> int.to_string(n)
    False -> int.to_string(n)
  }
}

fn pad4(n: Int) -> String {
  let s = int.to_string(n)
  string.pad_start(s, 4, "0")
}
