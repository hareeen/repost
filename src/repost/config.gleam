//// Loads shim configuration from environment variables.

import envoy
import gleam/int
import gleam/list
import gleam/result
import gleam/string

pub type Config {
  Config(
    shim_access_key_id: String,
    shim_secret_access_key: String,
    shim_region: String,
    r2_account_id: String,
    r2_access_key_id: String,
    r2_secret_access_key: String,
    r2_bucket: String,
    allowed_origins: List(String),
    max_upload_bytes: Int,
    shim_base_host: String,
    bind_interface: String,
    port: Int,
  )
}

pub type ConfigError {
  MissingVariable(name: String)
  InvalidVariable(name: String, value: String)
}

pub const default_max_upload_bytes: Int = 26_214_400

pub const default_port: Int = 4000

pub const default_bind_interface: String = "0.0.0.0"

pub fn load() -> Result(Config, ConfigError) {
  use shim_access_key_id <- result.try(required("SHIM_ACCESS_KEY_ID"))
  use shim_secret_access_key <- result.try(required("SHIM_SECRET_ACCESS_KEY"))
  use shim_region <- result.try(required("SHIM_REGION"))
  use r2_account_id <- result.try(required("R2_ACCOUNT_ID"))
  use r2_access_key_id <- result.try(required("R2_ACCESS_KEY_ID"))
  use r2_secret_access_key <- result.try(required("R2_SECRET_ACCESS_KEY"))
  use r2_bucket <- result.try(required("R2_BUCKET"))
  use allowed_origins_raw <- result.try(required("ALLOWED_ORIGINS"))
  let allowed_origins = parse_origin_list(allowed_origins_raw)

  use max_upload_bytes <- result.try(positive_int_or_default(
    "MAX_UPLOAD_BYTES",
    default_max_upload_bytes,
  ))
  let shim_base_host =
    envoy.get("SHIM_BASE_HOST")
    |> result.unwrap("")
  let bind_interface =
    envoy.get("BIND_INTERFACE")
    |> result.unwrap(default_bind_interface)
  use port <- result.try(positive_int_or_default("PORT", default_port))

  Ok(Config(
    shim_access_key_id:,
    shim_secret_access_key:,
    shim_region:,
    r2_account_id:,
    r2_access_key_id:,
    r2_secret_access_key:,
    r2_bucket:,
    allowed_origins:,
    max_upload_bytes:,
    shim_base_host:,
    bind_interface:,
    port:,
  ))
}

fn required(name: String) -> Result(String, ConfigError) {
  case envoy.get(name) {
    Ok(value) ->
      case string.trim(value) {
        "" -> Error(MissingVariable(name))
        trimmed -> Ok(trimmed)
      }
    Error(_) -> Error(MissingVariable(name))
  }
}

fn positive_int_or_default(
  name: String,
  default: Int,
) -> Result(Int, ConfigError) {
  case envoy.get(name) {
    Error(_) -> Ok(default)
    Ok(value) -> {
      let trimmed = string.trim(value)
      case trimmed {
        "" -> Ok(default)
        _ ->
          case int.parse(trimmed) {
            Ok(n) if n > 0 -> Ok(n)
            _ -> Error(InvalidVariable(name, value))
          }
      }
    }
  }
}

fn parse_origin_list(raw: String) -> List(String) {
  raw
  |> string.split(on: ",")
  |> list.map(string.trim)
  |> list.filter(fn(s) { s != "" })
}
