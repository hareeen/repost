# repost specification

repost accepts browser S3 POST Object uploads and re-uploads the files to Cloudflare R2.

## 1. Problem

Cloudflare R2 is S3-compatible, but it does not implement S3 POST Object.
In that flow, the browser sends a `multipart/form-data` form that carries a Base64-encoded policy document and an HMAC signature.
R2 answers these requests with `501 Not Implemented`.

Apps that upload this way, such as Outline, cannot use R2 without changes.

## 2. Goals

repost is an app-agnostic HTTP shim that:

1. Accepts S3 POST Object requests from the app's browser client.
2. Validates the policy and its SigV4 signature.
3. Re-uploads the file to R2 with requests signed by R2 credentials.

The only change on the app side is pointing its upload URL at repost.

## 3. Non-goals

- Full S3 API compatibility.
  repost handles uploads only; the app reads objects (GetObject, ListObjects and so on) from R2 directly.
- Accepting the S3 multipart upload API from clients.
  repost uses multipart uploads toward R2 internally, but clients only ever send a single POST.
- Files larger than 5 GB.
- Storage backends other than Cloudflare R2.

## 4. Technology

- **Language:** Gleam on BEAM/OTP.
- **HTTP server:** `mist`.
- **Cryptography:** `gleam_crypto` (HMAC-SHA256).
- **R2 client:** `gleam_httpc` with hand-written SigV4 signing; no AWS SDK.

## 5. Configuration

The README lists every environment variable.
Three relationships matter to the protocol:

- The app's access key ID, secret and region must equal `SHIM_ACCESS_KEY_ID`, `SHIM_SECRET_ACCESS_KEY` and `SHIM_REGION`.
  The app signs policies with them, and repost verifies with them.
- The app's bucket name must equal `R2_BUCKET`.
- `R2_ACCESS_KEY_ID` and `R2_SECRET_ACCESS_KEY` are known only to repost.

## 6. Wire protocol

### 6.1 Routing

repost resolves the bucket from the request, in path style or virtual-host style:

```
SHIM_BASE_HOST = "s3-shim.example.com"   (empty disables virtual-host routing)

if SHIM_BASE_HOST is empty or Host == SHIM_BASE_HOST:
    bucket = first path segment
else if Host ends with "." + SHIM_BASE_HOST:
    bucket = the part of Host before "." + SHIM_BASE_HOST
else:
    404 NoSuchBucket
```

The bucket must be a valid S3 bucket name and must equal `R2_BUCKET`; otherwise the response is `404 NoSuchBucket`.
Only the bucket root is served: `OPTIONS` and `POST` on a deeper path also return `404`, and any other method returns `405 MethodNotAllowed`.

Virtual-host routing needs wildcard DNS and TLS for `*.s3-shim.example.com`, for example through a DNS-01 ACME challenge or the Cloudflare proxy.
It does not affect signature verification, because the POST policy's string-to-sign does not include the `Host` header.

### 6.2 `OPTIONS /{bucket}`: CORS preflight

If the `Origin` header is in `ALLOWED_ORIGINS`, repost answers `204 No Content` with:

```
Access-Control-Allow-Origin: <the request's Origin>
Access-Control-Allow-Methods: POST
Access-Control-Allow-Headers: content-type, x-amz-*
Access-Control-Max-Age: 3600
Vary: Origin
```

A missing or unlisted origin gets `403 AccessDenied`.

### 6.3 `POST /{bucket}`: upload

The request is `multipart/form-data`.
Field names are case-insensitive, and every field must come before `file`.

| Field              | Description                                                        |
| ------------------ | ------------------------------------------------------------------ |
| `key`              | Object key, e.g. `uploads/2024/photo.png`. Must not be empty.      |
| `policy`           | Base64-encoded JSON policy document.                               |
| `x-amz-algorithm`  | Must be `AWS4-HMAC-SHA256`.                                        |
| `x-amz-credential` | `{AccessKeyId}/{YYYYMMDD}/{region}/s3/aws4_request`.               |
| `x-amz-date`       | `YYYYMMDDTHHMMSSZ`.                                                |
| `x-amz-signature`  | Hex-encoded HMAC-SHA256 signature.                                 |
| `Content-Type`     | Optional. Stored as the object's content type.                     |
| `file`             | The file. Must be the last part, and there must be exactly one.    |

Any other field must be covered by a policy condition (§7.2).

Text fields are read before the request is authenticated, so repost limits them:

| Limit                                         | Value  |
| --------------------------------------------- | ------ |
| Text fields per request                       | 64     |
| Total bytes of text field names and values    | 1 MiB  |
| Bytes per part header                         | 64 KiB |

On success, repost answers `204 No Content` with:

```
ETag: <the ETag returned by R2>
Access-Control-Allow-Origin: <the request's Origin>
Access-Control-Expose-Headers: ETag
Vary: Origin
```

### 6.4 Errors

Errors carry a minimal S3-style XML body:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<Error><Code>...</Code><Message>...</Message></Error>
```

Every error response sets `Connection: close`, so a client that is still sending the body sees the upload end.
When the origin is allowed, errors also carry `Access-Control-Allow-Origin` and `Vary: Origin`.

| Status | Code                    | When                                                                                          |
| ------ | ----------------------- | --------------------------------------------------------------------------------------------- |
| 400    | `InvalidRequest`        | The body is not valid multipart, a field is missing or empty, the algorithm is unsupported, the credential, policy or expiration is malformed, a form limit is exceeded, or a field follows `file`. |
| 400    | `EntityTooLarge`        | The file grows past the size limit (§8).                                                      |
| 403    | `AccessDenied`          | The origin is missing or not allowed, the policy has expired, a condition fails, or the file is below the policy's minimum size. |
| 403    | `SignatureDoesNotMatch` | The credential does not match repost's key, region, service or date, or the signature is wrong. |
| 404    | `NoSuchBucket`          | The bucket cannot be resolved or is not `R2_BUCKET`.                                          |
| 405    | `MethodNotAllowed`      | The method is not `OPTIONS` or `POST`.                                                        |
| 500    | `InternalError`         | repost itself failed.                                                                         |
| 502    | `InternalError`         | R2 rejected a request or could not be reached.                                                |

## 7. Validation

Checks run in this order, and the first failure decides the response.

Before any field is read:

1. The bucket resolves and equals `R2_BUCKET` (§6.1).
2. The `Origin` header is in `ALLOWED_ORIGINS`.
3. The request is `multipart/form-data` with a boundary.

While reading text fields, the form limits in §6.3 apply, and every value must be valid UTF-8.

When the `file` part starts:

4. All required fields from §6.3 are present, and `key` is not empty.
5. `x-amz-algorithm` is `AWS4-HMAC-SHA256`.
6. `x-amz-credential` parses as `{AK}/{Date}/{Region}/{Service}/aws4_request`, where `AK` equals `SHIM_ACCESS_KEY_ID`, `Region` equals `SHIM_REGION`, `Service` is `s3`, and `Date` equals the first 8 characters of `x-amz-date`.
7. `policy` Base64-decodes to a JSON policy.
8. The policy's `expiration` (RFC 3339) is in the future.
9. Every policy condition except `content-length-range` holds, and every field is covered (§7.2).
10. The signature is valid (§7.1).

While the file streams, the upload stops with `EntityTooLarge` as soon as the byte count passes the upper bound (§8).
At the end of the file, a file shorter than the policy's `content-length-range` minimum is rejected with `AccessDenied`.

### 7.1 Signature verification

The string-to-sign is the Base64-encoded policy exactly as sent, not the decoded JSON:

```
StringToSign         = <Base64-encoded policy, verbatim>

DateKey              = HMAC-SHA256("AWS4" + SHIM_SECRET_ACCESS_KEY, YYYYMMDD)
DateRegionKey        = HMAC-SHA256(DateKey, Region)
DateRegionServiceKey = HMAC-SHA256(DateRegionKey, "s3")
SigningKey           = HMAC-SHA256(DateRegionServiceKey, "aws4_request")

expected             = hex(HMAC-SHA256(SigningKey, StringToSign))
```

repost compares `expected` with `x-amz-signature` in constant time.

### 7.2 Policy conditions

repost enforces the [AWS POST policy conditions](https://docs.aws.amazon.com/AmazonS3/latest/API/sigv4-HTTPPOSTConstructPolicy.html) strictly.

| Syntax                                | Meaning                                              |
| ------------------------------------- | ---------------------------------------------------- |
| `{"field": "value"}`                  | Exact match.                                         |
| `["eq", "$field", "value"]`           | Exact match.                                         |
| `["starts-with", "$field", "prefix"]` | The value starts with `prefix`; `""` allows any value. |
| `["content-length-range", min, max]`  | The file is between `min` and `max` bytes.           |

The rules:

1. Every condition must hold.
2. Every form field must be covered by at least one condition, except `file`, `policy`, `x-amz-signature`, `x-amz-algorithm`, `x-amz-credential`, `x-amz-date` and `x-amz-security-token`.
3. The request's bucket counts as a `bucket` field, so a `bucket` condition is checked against the bucket resolved in §6.1.
4. Field names match case-insensitively; values match case-sensitively.
5. A `starts-with` condition covers exactly one field.
   `["starts-with", "$x-amz-meta-foo", ""]` covers `x-amz-meta-foo` only; AWS has no syntax that covers several fields by name prefix.

The check, in pseudocode:

```
covered = empty set

for each condition c:
  match c:
    Eq(field, value):
      fail with ConditionMismatch(field) unless form_fields[field] == value
      add field to covered
    StartsWith(field, prefix):
      fail with ConditionMismatch(field) unless form_fields[field] starts with prefix
      add field to covered
    ContentLengthRange(min, max):
      fail with LengthOutOfRange unless min <= file_size <= max

for each field in form_fields:
  fail with UncoveredField(field) unless field is exempt or in covered
```

The tests cover at least: the happy path, an exact-match violation, a prefix violation, a size outside `content-length-range`, and an uncovered extra field.

## 8. Upload to R2

repost never forwards the browser's request.
It takes only the file bytes and sends new requests to `https://{R2_ACCOUNT_ID}.r2.cloudflarestorage.com/{R2_BUCKET}/{key}`, signed with `R2_ACCESS_KEY_ID` and `R2_SECRET_ACCESS_KEY`.
The browser-to-repost and repost-to-R2 signatures are independent.

The size limit is the smaller of the policy's `content-length-range` maximum and `MAX_UPLOAD_BYTES`.

repost buffers the file in 5 MiB parts:

- A file of at most one part goes up as a single `PutObject` request.
- A larger file goes up as `CreateMultipartUpload`, then `UploadPart` for each part, then `CompleteMultipartUpload`.
  Every part except the last is exactly 5 MiB, as R2 requires.
  If anything fails after the upload is created, repost sends `AbortMultipartUpload` before it responds.
  If the abort fails too, the error message says so.
- The form's `Content-Type` field, if present, becomes the object's content type.

Each upload holds about one part plus one 64 KiB network chunk in memory, briefly doubling while a part is assembled.

On success repost returns `204` with R2's `ETag`; if R2 fails, it returns `502 InternalError`.

## 9. Security

- repost is exposed on the public internet, and **signature verification is its only access control**.
- Signatures are compared in constant time.
- `SHIM_SECRET_ACCESS_KEY` lives only on the app server and on repost.
- `R2_SECRET_ACCESS_KEY` lives only on repost; the app and the browser never see it.
- Uploads can only reach `R2_BUCKET`, whatever bucket the request names.
- The form limits in §6.3 bound what an unauthenticated client can make repost buffer.
- Replay protection relies on a short policy `expiration`.
  Single-use policies (for example, nonce tracking) are not implemented yet.
