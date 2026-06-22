# repost: S3 POST → R2 PUT Shim

## 1. Problem

Cloudflare R2 is S3-compatible but does **not** implement the S3 POST Object API—the browser-based upload flow where the client sends a `multipart/form-data` request containing a Base64-encoded policy document and an HMAC signature. R2 returns `501 Not Implemented` for these requests.

Applications that rely on this upload mechanism (e.g., Outline wiki) cannot use R2 as a storage backend without modification.

## 2. Goal

Build an application-agnostic HTTP shim that:

1. Accepts S3 POST Object requests from the application's browser client.
2. Validates the presigned policy and SigV4 signature.
3. Re-uploads the file to R2 using a standard `PUT` Object request signed with R2 credentials.

The only change required on the application side is pointing `AWS_S3_UPLOAD_BUCKET_URL` at the shim's domain.

## 3. Non-Goals

- Full S3 API compatibility. The shim handles the upload path only; reads (GetObject, ListObjects, etc.) go directly from the application to R2.
- S3 Multipart Upload API (`CreateMultipartUpload`, `UploadPart`, `CompleteMultipartUpload`).
- Files larger than 5 GB.
- Storage backends other than Cloudflare R2.

## 4. Technology

- **Language:** Gleam (runs on BEAM/OTP).
- **HTTP server:** `wisp` + `mist`.
- **Cryptography:** `gleam_crypto` (HMAC-SHA256).
- **R2 client:** Hand-rolled SigV4 signing + `gleam_httpc`. No AWS SDK dependency—PutObject is a single `PUT` request, roughly 50 lines of signing code.

## 5. Configuration

### 5.1 Application Side (e.g., Outline `.env`)

| Variable                    | Example Value                 | Notes                                                        |
| --------------------------- | ----------------------------- | ------------------------------------------------------------ |
| `AWS_S3_UPLOAD_BUCKET_URL`  | `https://s3-shim.example.com` | Points at the shim, not R2 directly.                         |
| `AWS_S3_UPLOAD_BUCKET_NAME` | `outline-uploads`             | The R2 bucket name.                                          |
| `AWS_ACCESS_KEY_ID`         | `shim-app-key`                | An arbitrary string the shim recognizes. Not a real AWS key. |
| `AWS_SECRET_ACCESS_KEY`     | `<shared secret>`             | Used to sign/verify policies between the app and the shim. **Not** the R2 secret. |
| `AWS_REGION`                | `auto`                        |                                                              |
| `AWS_S3_FORCE_PATH_STYLE`   | `true`                        | Required for MVP (path-style routing).                       |

### 5.2 Shim Side

| Variable                | Description                                                                 |
| ----------------------- | --------------------------------------------------------------------------- |
| `SHIM_ACCESS_KEY_ID`    | Must match the app's `AWS_ACCESS_KEY_ID`.                                   |
| `SHIM_SECRET_ACCESS_KEY`| Must match the app's `AWS_SECRET_ACCESS_KEY`. Used to verify policy signatures. |
| `SHIM_REGION`           | Region string used during SigV4 verification (e.g., `auto`).               |
| `R2_ACCOUNT_ID`         | Cloudflare account ID.                                                      |
| `R2_ACCESS_KEY_ID`      | R2 API token key ID.                                                        |
| `R2_SECRET_ACCESS_KEY`  | R2 API token secret.                                                        |
| `R2_BUCKET`             | Target R2 bucket name.                                                      |
| `ALLOWED_ORIGINS`       | Comma-separated list of allowed CORS origins.                               |
| `MAX_UPLOAD_BYTES`      | Maximum file size in bytes. Default: `26214400` (25 MiB).                   |

## 6. Wire Protocol (MVP — Path-Style Only)

### 6.1 `OPTIONS /{bucket}`

Handles CORS preflight.

**Response (204 No Content):**

```
Access-Control-Allow-Origin: <echoed Origin if it appears in ALLOWED_ORIGINS; otherwise 403>
Access-Control-Allow-Methods: POST
Access-Control-Allow-Headers: content-type, x-amz-*
Access-Control-Max-Age: 3600
Vary: Origin
```

### 6.2 `POST /{bucket}`

**Request:** `Content-Type: multipart/form-data` with the following fields (order matters—`file` must be last):

| Field                | Description                                                     |
| -------------------- | --------------------------------------------------------------- |
| `key`                | Object key (e.g., `uploads/2024/photo.png`).                    |
| `policy`             | Base64-encoded JSON policy document.                            |
| `x-amz-algorithm`    | Must be `AWS4-HMAC-SHA256`.                                     |
| `x-amz-credential`   | `{AccessKeyId}/{YYYYMMDD}/{region}/s3/aws4_request`.            |
| `x-amz-date`         | `YYYYMMDDTHHMMSSZ`.                                             |
| `x-amz-signature`    | Hex-encoded HMAC-SHA256 signature.                              |
| `file`               | The file payload. Must be the last field in the form.           |

**Success Response (204 No Content):**

```
ETag: <ETag returned by R2>
Access-Control-Allow-Origin: <echoed Origin>
Access-Control-Expose-Headers: ETag
```

### 6.3 Error Responses

Errors use a minimal S3-style XML body:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<Error>
  <Code>...</Code>
  <Message>...</Message>
</Error>
```

| Condition                             | HTTP Status | Code                    |
| ------------------------------------- | ----------- | ----------------------- |
| Signature mismatch                    | 403         | `SignatureDoesNotMatch` |
| Expired policy / condition violation / origin denied | 403 | `AccessDenied`      |
| Missing required field / malformed policy | 400     | `InvalidRequest`        |
| File exceeds size limit               | 400         | `EntityTooLarge`        |
| R2 upstream failure                   | 502         | `InternalError`         |

## 7. Validation Pipeline

Checks run in order. The first failure short-circuits the response.

1. **Origin check** — The request's `Origin` header must appear in `ALLOWED_ORIGINS`.
2. **Required fields** — All fields from §6.2 must be present.
3. **Algorithm** — `x-amz-algorithm` must equal `AWS4-HMAC-SHA256`.
4. **Credential parsing** — Parse `x-amz-credential` as `{AK}/{Date}/{Region}/s3/aws4_request`:
   - `AK` must equal `SHIM_ACCESS_KEY_ID`.
   - `Region` must equal `SHIM_REGION`.
   - `Date` (YYYYMMDD) must match the first 8 characters of `x-amz-date`.
5. **Policy decode** — Base64-decode `policy` and parse as JSON.
6. **Expiration** — `policy.expiration` (RFC 3339) must be in the future.
7. **Conditions (MVP — minimal):**
   - If the policy contains a `bucket` condition, it must match `{bucket}` from the request path.
   - If the policy contains a `content-length-range` condition, the file size must fall within `[min, max]`.
   - All other conditions are accepted without enforcement. (See §10 for strict mode.)
8. **Signature** — Verify per §7.1 below.
9. **File size** — The `file` field must not exceed `MAX_UPLOAD_BYTES`.

### 7.1 SigV4 POST Policy Signature Verification

The string-to-sign for an S3 POST policy is the **raw Base64-encoded policy string** (not the decoded JSON):

```
StringToSign = <Base64-encoded policy, verbatim>

DateKey      = HMAC-SHA256("AWS4" + SHIM_SECRET_ACCESS_KEY, YYYYMMDD)
DateRegionKey = HMAC-SHA256(DateKey, Region)
DateRegionServiceKey = HMAC-SHA256(DateRegionKey, "s3")
SigningKey   = HMAC-SHA256(DateRegionServiceKey, "aws4_request")

expected     = hex(HMAC-SHA256(SigningKey, StringToSign))
```

Compare `expected` against `x-amz-signature` using constant-time equality.

## 8. R2 Upload

After validation passes:

1. **Build the PUT request:**
   - URL: `https://{R2_ACCOUNT_ID}.r2.cloudflarestorage.com/{R2_BUCKET}/{key}`
   - Method: `PUT`
   - Body: Stream the `file` field bytes directly. Do not buffer the entire file in memory.
   - Headers: `Content-Type` from the form's `Content-Type` field (if provided), plus SigV4 authorization headers signed with `R2_ACCESS_KEY_ID` / `R2_SECRET_ACCESS_KEY`.

2. **Forward the result:**
   - On success: return `204` to the client with R2's `ETag` header and the appropriate CORS headers.
   - On failure: return `502 InternalError`.

**Key architectural point:** The shim does _not_ forward the original signed request to R2. It extracts only the file bytes and constructs a completely new PutObject request signed with R2 credentials. The browser↔shim signature and the shim↔R2 signature are independent; the only thing they share is the file content.

## 9. v2 — Virtual-Host Style Routing

### 9.1 Infrastructure Requirements

- **Wildcard DNS:** `*.s3-shim.example.com` → shim server.
- **Wildcard TLS:** Either DNS-01 ACME challenge (e.g., Let's Encrypt) or Cloudflare proxy with Universal SSL.
- **Ingress:** Catch-all for `*.s3-shim.example.com`.

### 9.2 Routing Logic

Determine the addressing mode from the `Host` header:

```
SHIM_BASE_HOST = "s3-shim.example.com"

if Host == SHIM_BASE_HOST:
    mode   = PathStyle
    bucket = first path segment

else if Host ends with "." + SHIM_BASE_HOST:
    mode   = VirtualHost
    bucket = leftmost subdomain label of Host

else:
    → 404 Not Found
```

### 9.3 Signature Compatibility

Virtual-host support has **no impact on signature verification**. The S3 POST policy's string-to-sign is the Base64 policy document only—it does not include the `Host` header. This is purely a routing and DNS concern.

### 9.4 Bucket Matching

The `bucket` condition in the policy (validation step 7) is compared against the bucket name extracted during routing, regardless of whether it was derived from the path or the hostname.

## 10. v2 — Strict Policy Condition Enforcement

Full enforcement of the [AWS S3 POST policy condition spec](https://docs.aws.amazon.com/AmazonS3/latest/API/sigv4-HTTPPOSTConstructPolicy.html).

### 10.1 Condition Grammar

| Syntax                                    | Semantics                        |
| ----------------------------------------- | -------------------------------- |
| `{"field": "value"}`                      | Exact match.                     |
| `["eq", "$field", "value"]`               | Exact match (alternative form).  |
| `["starts-with", "$field", "prefix"]`     | Value prefix match. `prefix=""` permits any value. |
| `["content-length-range", min, max]`      | File size in bytes must be within `[min, max]`. |

### 10.2 Enforcement Rules

1. **Every declared condition must be satisfied.** Each condition is evaluated against the corresponding form field.
2. **Every form field must be covered.** Any form field not mentioned by at least one condition is rejected, with the following exempt fields:
   - `file`, `policy`, `x-amz-signature`, `x-amz-algorithm`, `x-amz-credential`, `x-amz-date`, `x-amz-security-token`
3. **`content-length-range`** — If the file size exceeds the upper bound during streaming, abort the read immediately.
4. **Field name matching** is case-insensitive; **value matching** is case-sensitive.
5. **Scope of `starts-with`** — `["starts-with", "$x-amz-meta-foo", ""]` covers only the single field `x-amz-meta-foo`. AWS does not define a wildcard syntax that covers multiple fields via prefix; the prefix applies to the field's _value_, not its name.

### 10.3 Type Definitions

```gleam
pub type Condition {
  Eq(field: String, value: String)
  StartsWith(field: String, prefix: String)
  ContentLengthRange(min: Int, max: Int)
}

pub type ValidationError {
  ConditionMismatch(field: String)
  UncoveredField(field: String)
  LengthOutOfRange
}

pub fn validate(
  conditions: List(Condition),
  form_fields: Dict(String, String),
  file_size: Int,
) -> Result(Nil, ValidationError)
```

### 10.4 Algorithm

```
covered = empty set
errors  = empty list

for each condition c:
  match c:
    Eq(field, value):
      if form_fields[field] != value → append ConditionMismatch(field)
      add field to covered

    StartsWith(field, prefix):
      if not form_fields[field].starts_with(prefix) → append ConditionMismatch(field)
      add field to covered

    ContentLengthRange(min, max):
      if not (min <= file_size <= max) → append LengthOutOfRange

for each field in form_fields.keys():
  if field is in EXEMPT_FIELDS → skip
  if field is not in covered → append UncoveredField(field)

return first error, or Ok
```

### 10.5 Test Vectors

Derive from the AWS documentation's example policy. Cover at minimum:

- Happy path: all conditions satisfied, all fields covered.
- Exact-match violation: declared value differs from form field value.
- Prefix violation: form field value does not start with declared prefix.
- Range violation: file size outside `content-length-range`.
- Uncovered field injection: form includes a field not declared in any condition.

## 11. Security Considerations

- The shim is exposed on public HTTPS. **Signature verification is the sole access-control mechanism.**
- Signature comparison uses constant-time equality to prevent timing attacks.
- `SHIM_SECRET_ACCESS_KEY` must be stored securely on both the application server and the shim. It never leaves these two systems.
- `R2_SECRET_ACCESS_KEY` is stored only on the shim. The application and browser never see it.
- **Replay protection** relies on the policy's short `expiration` window. Single-use enforcement (e.g., nonce tracking) is deferred to v3.
