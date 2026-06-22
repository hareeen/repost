# repost

A streaming HTTP shim that translates browser-issued S3 POST Object uploads into SigV4-signed PUT requests against Cloudflare R2.
The full protocol spec lives in [`spec.md`](spec.md).

Built in Gleam on BEAM/OTP.
File bytes flow from the browser through `mist.stream`, the multipart parser, and `ssl:send` to R2 with no disk hop and no in-RAM accumulation past one chunk in flight (~64 KiB).

## Configuration

All configuration is loaded from environment variables at startup.
The process exits with a precise error if any required variable is missing.

| Variable                  | Required | Default      | Description                                                                |
| ------------------------- | :------: | ------------ | -------------------------------------------------------------------------- |
| `SHIM_ACCESS_KEY_ID`      |    ✓     |              | The "access key" the application uses against the shim. Not a real AWS key.|
| `SHIM_SECRET_ACCESS_KEY`  |    ✓     |              | Shared secret used to verify POST policy signatures.                       |
| `SHIM_REGION`             |    ✓     |              | Region string used in SigV4 verification (typically `auto`).               |
| `R2_ACCOUNT_ID`           |    ✓     |              | Cloudflare account ID.                                                     |
| `R2_ACCESS_KEY_ID`        |    ✓     |              | R2 API token key ID.                                                       |
| `R2_SECRET_ACCESS_KEY`    |    ✓     |              | R2 API token secret.                                                       |
| `R2_BUCKET`               |    ✓     |              | Target R2 bucket name.                                                     |
| `ALLOWED_ORIGINS`         |    ✓     |              | Comma-separated list of allowed CORS origins.                              |
| `MAX_UPLOAD_BYTES`        |          | `26214400`   | Maximum file size in bytes (25 MiB default).                               |
| `SHIM_BASE_HOST`          |          | (empty)      | Bare hostname (e.g. `s3-shim.example.com`). Enables virtual-host routing.  |
| `BIND_INTERFACE`          |          | `0.0.0.0`    | Interface to bind on.                                                      |
| `PORT`                    |          | `4000`       | TCP port.                                                                  |

## Run locally

```sh
gleam run        # foreground, with env vars set in the shell
gleam test       # 98 unit + integration + e2e tests
```

## Run in Docker

```sh
docker build -t repost .
docker run --rm -p 4000:4000 \
  -e SHIM_ACCESS_KEY_ID=shim-app-key \
  -e SHIM_SECRET_ACCESS_KEY=... \
  -e SHIM_REGION=auto \
  -e R2_ACCOUNT_ID=... \
  -e R2_ACCESS_KEY_ID=... \
  -e R2_SECRET_ACCESS_KEY=... \
  -e R2_BUCKET=outline-uploads \
  -e ALLOWED_ORIGINS=https://outline.example.com \
  repost
```

## Module layout

- `repost/streaming_handler` is the mist entry point: it routes the request, dispatches uploads to the pump, and forces `Connection: close` on every error so mid-stream aborts (spec §10.2.3) are observable on the wire.
- `repost/streaming/pump` runs the multipart event loop, accumulates text fields, validates them against the POST policy, opens the R2 connection, and forwards file chunks one at a time.
- `repost/multipart_stream` is an incremental multipart parser built on `gleam_http`'s continuations.
- `repost/r2_stream` (with the `repost_stream_ffi.erl` FFI) is a chunked HTTP/1.1 PUT client over `gen_tcp` / `ssl`.
- `repost/sigv4` derives signing keys, verifies the browser's POST policy signature, and signs the outgoing PUT.
- `repost/pipeline`, `repost/policy`, `repost/validator` cover the spec §7 + §10 validation pipeline.
- `repost/router` extracts the bucket from path-style or virtual-host requests.
- `repost/cors` and `repost/errors` cover CORS allow-list logic and S3-style XML error responses.

## Tests

```sh
gleam test
```

Suite includes:

- SigV4 vectors cross-validated against an independent Python `hmac` reference (signing-key derivation, POST-policy signature, PUT signature).
- `validator` over every §10.5 condition shape (eq, starts-with, content-length-range, coverage check, exempt list).
- `multipart_stream` proves chunks of the file part arrive incrementally even when the parser is fed 17-byte transport chunks.
- `r2_stream` runs against a live mist server playing the role of R2, exercising `gen_tcp` / `ssl` send + chunked response decoding.
- `streaming_e2e_test` boots the shim and a fake R2, sends a real chunked HTTP/1.1 multipart POST, and verifies bytes round-trip plus mid-stream `content-length-range` abort behaviour (spec §10.2.3).

## License

Apache-2.0.
