//// Process entry point: load config, start mist with the streaming handler.

import gleam/erlang/process
import gleam/io
import mist

import repost/config
import repost/streaming_handler

pub fn main() -> Nil {
  case config.load() {
    Error(err) -> {
      io.println_error("repost: invalid configuration — " <> describe(err))
      panic as "missing or invalid configuration"
    }
    Ok(cfg) -> {
      let deps = streaming_handler.default_deps(cfg)
      let assert Ok(_) =
        mist.new(streaming_handler.handle(_, deps))
        |> mist.bind(cfg.bind_interface)
        |> mist.port(cfg.port)
        |> mist.start

      process.sleep_forever()
    }
  }
}

fn describe(err: config.ConfigError) -> String {
  case err {
    config.MissingVariable(name:) -> "missing env var " <> name
    config.InvalidVariable(name:, value:) ->
      "invalid env var " <> name <> "=" <> value
  }
}
