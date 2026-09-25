# repost

A streaming HTTP shim that translates browser-issued S3 POST Object uploads into SigV4-signed requests against Cloudflare R2.
The full protocol spec lives in [`spec.md`](spec.md).

Built in Gleam on BEAM/OTP.
File bytes flow from the browser through `mist.stream` and the multipart parser to R2 through `gleam_httpc`, without a disk hop.
Each in-flight upload buffers roughly one 5 MiB part plus one transport chunk; bytes cut from a joined buffer can briefly keep up to about twice the part size (about 10 MiB by default) alive between flushes.

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
gleam test       # 130 unit, integration, and e2e tests
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

- `repost/server` handles mist requests; `repost/server/response` builds upload responses.
- `repost/upload` runs the multipart event loop; `repost/upload/sink` buffers parts and selects a single PUT or R2 multipart upload.
- `repost/authorize`, `repost/policy`, and `repost/policy/validator` validate POST policies and form fields.
- `repost/multipart` parses incoming multipart forms; `repost/multipart/boundary` handles boundaries.
- `repost/sigv4` signs R2 requests and verifies POST signatures; `repost/sigv4/uri` encodes request paths.
- `repost/r2` sends signed requests through `gleam_httpc`; `repost/r2/put_object`, `repost/r2/multipart_upload`, and `repost/r2/xml` handle R2 operations and responses.
- `repost/router`, `repost/cors`, and `repost/errors` handle routing, CORS, and S3-style errors.
- `repost/config` loads settings; `repost/time` provides time formatting.

## Tests

```sh
gleam test
```

Suite includes:

- SigV4 vectors cross-validated against an independent Python `hmac` reference (signing-key derivation, POST-policy signature, and signed R2 requests).
- Policy validation over every §10.5 condition shape (eq, starts-with, content-length-range, coverage check, exempt list).
- Multipart parsing with transport chunks crossing form boundaries.
- R2 request and XML tests, including multipart operations and an error inside a successful HTTP response.
- End-to-end tests with a chunked HTTP/1.1 browser request and a fake R2 verify single PUT for files up to one part, byte-exact multipart uploads for larger files, and aborts on size limits and R2 failures.

## Operations

Configure an R2 lifecycle rule to abort incomplete multipart uploads after 1 day.
A process crash during an upload cannot run the abort request, so the rule clears orphaned uploads.

## License

Apache-2.0.
