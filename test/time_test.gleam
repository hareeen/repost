//// ISO 8601 / RFC 3339 expiration parsing via the Erlang FFI.

import repost/time

pub fn parses_basic_utc_test() {
  // 2024-01-01T00:00:00Z = 1704067200 in Unix seconds.
  assert time.parse_iso8601_utc("2024-01-01T00:00:00Z") == Ok(1_704_067_200)
}

pub fn parses_lowercase_z_test() {
  assert time.parse_iso8601_utc("2024-01-01t00:00:00z") == Ok(1_704_067_200)
}

pub fn parses_fractional_seconds_test() {
  assert time.parse_iso8601_utc("2024-01-01T00:00:00.999Z") == Ok(1_704_067_200)
}

pub fn parses_offset_timezone_test() {
  // 2024-01-01T05:00:00+05:00 == 2024-01-01T00:00:00Z
  assert time.parse_iso8601_utc("2024-01-01T05:00:00+05:00")
    == Ok(1_704_067_200)
}

pub fn parses_negative_offset_test() {
  // 2023-12-31T19:00:00-05:00 == 2024-01-01T00:00:00Z
  assert time.parse_iso8601_utc("2023-12-31T19:00:00-05:00")
    == Ok(1_704_067_200)
}

pub fn rejects_garbage_test() {
  assert time.parse_iso8601_utc("not a date") == Error(time.Malformed)
}

pub fn rejects_missing_time_zone_test() {
  // Erlang's calendar:rfc3339_to_system_time requires a time zone.
  let result = time.parse_iso8601_utc("2024-01-01T00:00:00")
  assert result == Error(time.Malformed)
}

pub fn format_amz_date_round_trip_test() {
  // 2024-01-01T00:00:00Z = 1704067200
  assert time.format_amz_date(1_704_067_200) == "20240101T000000Z"
}

pub fn now_seconds_increases_test() {
  let a = time.now_seconds_utc()
  let b = time.now_seconds_utc()
  assert b >= a
}
