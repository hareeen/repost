# repost

repost lets browser apps upload to Cloudflare R2 with S3 POST Object forms.

R2 is S3-compatible, but it rejects POST Object uploads with `501 Not Implemented`.
Apps such as Outline rely on that flow, so they cannot use R2 as-is.
repost sits in front of R2, checks each form's policy and signature, and re-uploads the file with its own R2 credentials.
The app only needs its upload URL pointed at repost.

The protocol and validation rules are specified in [`spec.md`](spec.md).

## How it works

1. The browser posts a `multipart/form-data` form, signed by the app, to repost.
2. repost reads the text fields and verifies the policy, credential and signature before it reads any file bytes.
3. repost streams the file to R2.
   Files up to 5 MiB go up as a single `PUT`.
   Larger files go up as an R2 multipart upload in 5 MiB parts, and a failure part-way aborts the upload.
4. repost returns `204` with R2's `ETag`, or an S3-style XML error.

File bytes never touch disk.
Each upload holds about one 5 MiB part plus one 64 KiB network chunk in memory, briefly doubling while a part is assembled.

## Quick start

With Docker, pull the published image.
It is a multi-arch image for `linux/amd64` and `linux/arm64`, so Docker picks the one matching your machine:

```sh
docker pull ghcr.io/hareeen/repost:main
```

Or, on Linux with Nix, build the image for your architecture (`amd64` or `arm64`) and load it into Docker as `repost:latest`:

```sh
nix build .#repost-image-amd64
nix run .#repost-image-amd64.copyTo -- docker-daemon:repost:latest
```

Each Linux system builds only its own architecture's image, because nixpkgs cannot cross-compile Erlang.
On macOS, build through a Linux builder such as nix-darwin's `nix.linux-builder`, naming the system explicitly:

```sh
nix build .#packages.aarch64-linux.repost-image-arm64
```

Then run it, naming `ghcr.io/hareeen/repost:main` instead of `repost` if you pulled it:

```sh
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

Without Docker, set the same variables in your shell and run `gleam run`.

## Configuration

### repost

repost reads its configuration from environment variables at startup.
If a required variable is missing or invalid, it exits and names the variable.

| Variable                 | Required | Default    | Description                                                                 |
| ------------------------ | :------: | ---------- | --------------------------------------------------------------------------- |
| `SHIM_ACCESS_KEY_ID`     |    ✓     |            | Access key the app signs with. An arbitrary string, not a real AWS key.     |
| `SHIM_SECRET_ACCESS_KEY` |    ✓     |            | Secret shared with the app, used to verify policy signatures.               |
| `SHIM_REGION`            |    ✓     |            | Region the app signs for, usually `auto`.                                   |
| `R2_ACCOUNT_ID`          |    ✓     |            | Cloudflare account ID.                                                      |
| `R2_ACCESS_KEY_ID`       |    ✓     |            | R2 API token key ID.                                                        |
| `R2_SECRET_ACCESS_KEY`   |    ✓     |            | R2 API token secret.                                                        |
| `R2_BUCKET`              |    ✓     |            | R2 bucket to upload into. Requests for any other bucket get `404`.          |
| `ALLOWED_ORIGINS`        |    ✓     |            | Comma-separated list of browser origins allowed to upload.                  |
| `MAX_UPLOAD_BYTES`       |          | `26214400` | Largest accepted file, in bytes (25 MiB).                                   |
| `SHIM_BASE_HOST`         |          | (empty)    | Bare hostname such as `s3-shim.example.com`. Enables virtual-host routing.  |
| `BIND_INTERFACE`         |          | `0.0.0.0`  | Interface to listen on.                                                     |
| `PORT`                   |          | `4000`     | TCP port to listen on.                                                      |

### The app

Point the app's S3 settings at repost and give it the shim credentials, not the R2 ones.
For Outline:

| Variable                    | Value                                             |
| --------------------------- | ------------------------------------------------- |
| `AWS_S3_UPLOAD_BUCKET_URL`  | repost's URL, e.g. `https://s3-shim.example.com`  |
| `AWS_S3_UPLOAD_BUCKET_NAME` | Same as `R2_BUCKET`                               |
| `AWS_ACCESS_KEY_ID`         | Same as `SHIM_ACCESS_KEY_ID`                      |
| `AWS_SECRET_ACCESS_KEY`     | Same as `SHIM_SECRET_ACCESS_KEY`                  |
| `AWS_REGION`                | Same as `SHIM_REGION`                             |
| `AWS_S3_FORCE_PATH_STYLE`   | `true`; may be `false` once `SHIM_BASE_HOST` is set |

Reads do not go through repost: the app still reads objects from R2 directly.

## Operations

Add an R2 lifecycle rule that aborts incomplete multipart uploads after one day.
repost aborts failed uploads itself, but if the process crashes mid-upload, the abort never runs and R2 keeps the partial upload.

Before a request is authenticated, repost caps what it will buffer: at most 64 text fields, 1 MiB of field names and values, and 64 KiB per part header.

## Development

```sh
gleam test    # 129 unit, integration and end-to-end tests
```

The end-to-end tests run repost against a fake R2 server and send real chunked HTTP/1.1 uploads.
They cover the single `PUT` and multipart paths byte for byte, size limits, and aborts after R2 failures.
The SigV4 test vectors are checked against an independent Python `hmac` implementation.

### Environment

The Nix flake pins Gleam, Erlang and rebar3.
Enter the shell with `nix develop`, or let direnv load it through the tracked `.envrc`.
The shell installs git hooks: `treefmt` runs before each commit, and `statix`, `deadnix` and `gleam build --warnings-as-errors` run before each push.
CI runs the same commands from the same flake, so local and CI results agree.

### Module layout

| Module                                                   | Responsibility                                                      |
| -------------------------------------------------------- | ------------------------------------------------------------------- |
| `repost/server`, `server/response`                       | HTTP entry point: routing, CORS, and building responses.            |
| `repost/upload`                                          | Reads form parts in order and hands the file to the sink.           |
| `repost/upload/sink`                                     | Buffers file bytes into parts and chooses single `PUT` or multipart. |
| `repost/authorize`, `policy`, `policy/validator`         | Checks the credential, signature, expiry and policy conditions.     |
| `repost/multipart`, `multipart/boundary`                 | Streaming `multipart/form-data` parser.                             |
| `repost/r2`, `r2/put_object`, `r2/multipart_upload`      | Signed requests to R2 over `gleam_httpc`.                           |
| `repost/sigv4`, `sigv4/uri`                              | SigV4 signing and POST policy signature verification.               |
| `repost/xml`                                             | Reads R2's XML responses and escapes XML text.                      |
| `repost/router`, `cors`, `errors`, `config`, `time`      | Bucket routing, CORS rules, S3 error bodies, settings, timestamps.  |

## License

Apache-2.0.
