# Bound upload memory with R2 multipart uploads and clear the chunked-PUT-era debt

Base: 1ecdec84338773ac2ed8f2939a093f64cfdf80b4

Objective: replace whole-file buffering with a hand-rolled R2 multipart upload (5 MiB parts) over `gleam_httpc`, with no production FFI, and restructure the modules so that adding one R2 operation touches one file plus its caller (today: 3 sites) and adding one validation step touches 2 sites (today: 3).

Approved findings: #1 dead code, #2 httpc transport, #3 phase sum type, #4 single validation orchestration, #5 Result-based pump, #6 redundant bucket check, #7 module tree, #8 stdlib reimplementations, #9 multipart sink, #10 docs.
Decisions: part size 5 MiB (test seam via `Deps`), R2 XML parsed by a small Gleam extractor, `gleam_httpc` instead of hackney.

Key assumptions:
- R2 requires every part except the last to be the same size and at least 5 MiB; part numbers are 1..10000.
- `CompleteMultipartUpload` can return HTTP 200 with an `<Error>` body; that must be treated as failure.
- `gleam_httpc` sets `Host` and `Content-Length` itself; the signed `host` value must equal what it sends, and neither header may be duplicated.

## Tasks

- [x] T0: Commit the already-landed security fixes as their own commit (bucket must equal `R2_BUCKET`, `pipeline.check_key` rejects empty keys, pump caps text fields at 64 and charges names against the 1 MiB cap).
  - Files: `src/repost/streaming_handler.gleam`, `src/repost/pipeline.gleam`, `src/repost/streaming/pump.gleam`, `test/streaming_e2e_test.gleam`
  - Context: already done and tested (104 passing); this task only commits.

- [x] T1: Delete standalone dead code (#1): `r2_put.open`, `Opened`, `transport_headers`, `strip_content_length`, `open_timeout_ms`; `multipart_stream.with_header_cap` (0 callers); unwrap `sigv4.PutSignOutput` so `sign_put` returns the header list; remove the unused `gleam_otp` dependency. Replace `policy.build_field_map` in tests with a local test helper and delete it from `src`.
  - Files: `src/repost/streaming/r2_put.gleam`, `src/repost/multipart_stream.gleam`, `src/repost/sigv4.gleam`, `src/repost/policy.gleam`, `gleam.toml`, `manifest.toml`, `test/validator_test.gleam`, `test/pipeline_test.gleam`, `test/sigv4_test.gleam`
  - Depends on: T0
  - Context: `pipeline.run` and friends are removed in T6, and `r2_stream.start/send_chunk/finish/close` in T4, because their test consumers need a replacement first.

- [x] T2: Replace stdlib reimplementations (#8), behavior-preserving: `int_min`/`int_max` → `int.min`/`int.max` (`pipeline.gleam`, `pump.gleam`); `concat_chunks` → `bit_array.concat`; `do_decode_conditions` → `list.try_map`; validator `MaybeField` → `option.Option`; `time.pad2`/`pad4` → `string.pad_start`.
  - Files: `src/repost/pipeline.gleam`, `src/repost/streaming/pump.gleam`, `src/repost/policy.gleam`, `src/repost/validator.gleam`, `src/repost/time.gleam`
  - Depends on: T1
  - Context: skip `r2_stream.encode/decode_headers`; that file is deleted in T5.

- [ ] T3: Module moves (#7), pure renames with no logic change. `streaming_handler` → `server`; `streaming/mist_response` → `server/response`; `multipart_stream` → `multipart`; `streaming/boundary` → `multipart/boundary`; `validator` → `policy/validator`; `pipeline` → `authorize`; `streaming/uri` → `sigv4/uri`; `streaming/pump` → `upload`; `streaming/r2_put` → `r2/put_object` (with `Endpoint` and the shared signed-request helper in `r2.gleam`). Delete the pass-through `streaming_handler.default_deps`; `repost.gleam` calls `upload.default_deps`. Rename test files to match.
  - Files: all of `src/repost/**`, `src/repost.gleam`, `test/*.gleam`
  - Depends on: T2
  - Context: use `git mv` so history follows. Dependencies point only downward: `server → upload → {authorize, r2} → sigv4`. The `streaming/` directory must be empty and removed at the end. Run this task alone; it touches every file.

- [ ] T4: Move the fake-browser chunked client into test support (#2, part 1). Add `test/support/raw_client.erl` (plain `gen_tcp`, sends headers, then body chunks, then reads the response; tolerates an early server hang-up) with a Gleam wrapper `test/support/raw_client.gleam`. Move the fake R2 server out of the e2e test into `test/support/fake_r2.gleam`. Switch all e2e callers, then delete `r2_stream.start/send_chunk/finish/close`, `StartError`, `SendError` and the matching FFI exports.
  - Files: `test/support/raw_client.erl`, `test/support/raw_client.gleam`, `test/support/fake_r2.gleam`, `test/streaming_e2e_test.gleam`, `src/repost/r2_stream.gleam`, `src/repost_stream_ffi.erl`
  - Depends on: T3
  - Context: the client sends `Transfer-Encoding: chunked` itself (hex size line + CRLF per chunk, `0\r\n\r\n` terminator); the tests rely on small transport chunks crossing part boundaries.

- [ ] T5: Replace hackney with `gleam_httpc` (#2, part 2) and generalize SigV4. `sigv4.sign(method, canonical_uri, query: List(#(String, String)), headers, payload_sha256_hex, amz_date, creds)` builds the canonical query string (sorted, RFC 3986 encoded, `uploads` → `uploads=`) and replaces `sign_put`. `r2.gleam` owns `Endpoint`, a `send(endpoint, creds, method, key, query, headers, body, now)` that signs and dispatches via `httpc.dispatch_bits` with a configured timeout, and maps transport failure to a typed error. Port `put_object` onto it. Delete `r2_stream.gleam`, `repost_stream_ffi.erl`, the `hackney` dependency and `extra_applications`.
  - Files: `src/repost/sigv4.gleam`, `src/repost/r2.gleam`, `src/repost/r2/put_object.gleam`, `gleam.toml`, `manifest.toml`, `test/sigv4_test.gleam`
  - Depends on: T4
  - Context: keep the existing PUT signing test vectors passing byte-for-byte; add one vector with a query string, cross-checked against a Python `hmac` reference like the existing ones. Check in the e2e capture that R2 sees exactly one `host` and one `content-length`. Behavior preserved: the happy-path e2e assertions stay unchanged.

- [ ] T6: One validation entry point (#4). Move `validate_pre_file`, `check_conditions_pre_size` and `without_length_conditions` from `upload` into `authorize.authorize(fields, bucket, config, now) -> Result(Authorized, ErrorResponse)`, where `Authorized(key, content_type, length_bounds)`. Delete `authorize.run`, `Inputs`, `ValidatedRequest`, `check_size`, `lookup_form_value`; make individual checks private unless a test needs them. Rewrite `authorize_test` (was `pipeline_test`) against `authorize`.
  - Files: `src/repost/authorize.gleam`, `src/repost/upload.gleam`, `test/authorize_test.gleam`
  - Depends on: T5
  - Context: the step order must stay: required, key, credential, policy, expiration, conditions without length, signature.

- [ ] T7: Remove the redundant `check_bucket_condition` (#6); the validator already checks the `bucket` Eq condition through the injected field. Update any test asserting the old message.
  - Files: `src/repost/authorize.gleam`, `test/authorize_test.gleam`
  - Depends on: T6
  - Context: behavior change, message only (`policy condition failed for field: bucket`); separate commit on purpose.

- [ ] T8: Phase sum type and Result errors in `upload` (#3, #5). Replace `ProcessState`'s `r2`/`policy_doc`/`current_field` with `CollectingFields(fields, bytes_used, count, current)` or `ReceivingFile(authorized, bytes_seen, chunks)`. The loop returns `Result(Uploaded(etag), ErrorResponse)`; `server` converts it to a response once (with `decision`). Delete the unreachable `NoR2`/`NoPolicy` branches and the stale "close R2" comment.
  - Files: `src/repost/upload.gleam`, `src/repost/server.gleam`
  - Depends on: T7
  - Context: still buffers the whole file in this task; T11 swaps in the sink. All existing e2e tests must pass unchanged.

- [ ] T9: R2 XML extractor. `r2/xml.gleam`: `element_text(xml, tag) -> Result(String, XmlError)` for the first `<tag>…</tag>`, decoding `&amp; &lt; &gt; &quot; &apos;`; `error_code(xml) -> Result(String, Nil)` to detect `<Error><Code>`. Typed errors, no sentinels.
  - Files: `src/repost/r2/xml.gleam`, `test/r2_xml_test.gleam`
  - Depends on: T5
  - Context: fixtures copied from AWS's documented `InitiateMultipartUploadResult`, `CompleteMultipartUploadResult`, and 200-with-`<Error>` responses.

- [ ] T10: Multipart operations. `r2/multipart_upload.gleam`: `create(…) -> Result(UploadId, R2Error)` (`POST ?uploads`), `upload_part(…, id, number, body) -> Result(PartEtag, R2Error)` (`PUT ?partNumber=&uploadId=`, `x-amz-content-sha256` = the part's hash), `complete(…, id, parts)` (`POST ?uploadId=`, XML body, treat an `<Error>` body as failure even on 200, return the final ETag), `abort(…, id)` (`DELETE ?uploadId=`). `UploadId`/`PartNumber` are opaque domain types. Extend `test/support/fake_r2.gleam` to serve all four and record calls.
  - Files: `src/repost/r2/multipart_upload.gleam`, `test/support/fake_r2.gleam`, `test/r2_multipart_upload_test.gleam`
  - Depends on: T9

- [ ] T11: Upload sink (#9). `upload/sink.gleam` holds `Pending(buffer)` or `Multipart(id, next_number, parts, buffer)`. `push(chunk)` appends; whenever the buffer reaches `part_size` it creates the upload if needed and sends exactly `part_size` bytes, keeping the remainder. `finish()` sends a single `put_object` when no upload was created, otherwise uploads the tail as the last part and completes. `abort()` is idempotent and a no-op before `create`. `upload` wires the sink in: the size limit is exceeded, the minimum length fails, a read/parse error happens, or an R2 call fails → `abort` then error. Add `part_size` to `Deps` (default `5 * 1024 * 1024`).
  - Files: `src/repost/upload/sink.gleam`, `src/repost/upload.gleam`, `test/upload_sink_test.gleam`, `test/streaming_e2e_test.gleam`
  - Depends on: T8, T10
  - Context: new e2e cases with a small `part_size`: a file smaller than one part goes as a single PUT; a file of several parts round-trips byte-exact with equal-size non-final parts; an upper-bound overflow after `create` makes the fake R2 see `DELETE ?uploadId`; a minimum-size failure aborts; a failing `UploadPart` aborts and returns 502. Memory: no field in the upload state may hold more than `part_size` + one transport chunk of file bytes.

- [ ] T12: Docs (#10). README: the actual memory bound (one part + one chunk per upload), the httpc transport, the module layout from T3, the test count, and a recommended R2 lifecycle rule to abort incomplete multipart uploads after 1 day (catches uploads orphaned by a crash). spec §4: mist + gleam_httpc, and note the multipart strategy under §8. Rename `happy_path_chunked_request_chunked_to_r2_test`.
  - Files: `README.md`, `spec.md`, `test/streaming_e2e_test.gleam`
  - Depends on: T11

- [ ] T13: Acceptance. Re-count touchpoints: adding one R2 operation should need 1 new file under `r2/` + its caller (was 3 sites); adding one validation step should need 2 sites in `authorize.gleam` (was 3). Zero-caller sweep over every `pub fn`/`pub type` in `src` (grep each name; flag any with no caller outside its own file and tests). Confirm there is no `.erl` under `src/`, no `hackney` in `gleam.toml`/`manifest.toml`, and no `src/repost/streaming/`. Run `gleam export erlang-shipment`. Report the numbers against the diagnosis.
  - Depends on: T12

## Verification
- L1 (each task): `gleam build && gleam test`, plus `gleam format --check` on the files the task touched
- L3 (final): `gleam format --check src test && gleam test && gleam export erlang-shipment`

## Rules
- Formatter version skew: CI pins Gleam 1.15.4, local is 1.18.1, and they disagree on some existing lines. Format only the files a task touches, and revert any rewrap of lines the task didn't change.
- Moves (T3) never share a commit with behavior changes; T7, T8 and T11 are the behavior-changing commits.
- Gleam modules: `foo.gleam` with children in `foo/`. Keep functions private by default; use `@internal` rather than `pub` when only tests need access.
- No new production FFI files. Erlang is allowed only under `test/support/`.
- Error handling: typed error variants per module (`R2Error`, `XmlError`); never map a failure to `""` or a default value.
- Commit per task inside `/implement`; never push.
