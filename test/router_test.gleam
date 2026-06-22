//// Router behaviour for path-style and virtual-host requests.

import repost/router

pub fn path_style_basic_test() {
  assert router.route(
      Ok("s3-shim.example.com"),
      ["my-bucket"],
      "s3-shim.example.com",
    )
    == router.BucketRoute(bucket: "my-bucket", remainder: [])
}

pub fn path_style_when_virtual_host_disabled_test() {
  assert router.route(Ok("anything"), ["my-bucket"], "")
    == router.BucketRoute(bucket: "my-bucket", remainder: [])
}

pub fn virtual_host_basic_test() {
  assert router.route(
      Ok("my-bucket.s3-shim.example.com"),
      [],
      "s3-shim.example.com",
    )
    == router.BucketRoute(bucket: "my-bucket", remainder: [])
}

pub fn virtual_host_with_port_test() {
  assert router.route(
      Ok("my-bucket.s3-shim.example.com:8443"),
      [],
      "s3-shim.example.com",
    )
    == router.BucketRoute(bucket: "my-bucket", remainder: [])
}

pub fn virtual_host_case_insensitive_test() {
  assert router.route(
      Ok("My-Bucket.S3-Shim.Example.COM"),
      [],
      "s3-shim.example.com",
    )
    == router.BucketRoute(bucket: "my-bucket", remainder: [])
}

pub fn unknown_host_returns_no_route_test() {
  assert router.route(
      Ok("attacker.example.org"),
      ["my-bucket"],
      "s3-shim.example.com",
    )
    == router.NoRoute
}

pub fn empty_path_path_style_returns_no_route_test() {
  assert router.route(Ok("s3-shim.example.com"), [], "s3-shim.example.com")
    == router.NoRoute
}

pub fn invalid_bucket_name_returns_no_route_test() {
  assert router.route(
      Ok("s3-shim.example.com"),
      ["BAD..bucket"],
      "s3-shim.example.com",
    )
    == router.NoRoute
}

pub fn path_traversal_attempt_returns_no_route_test() {
  assert router.route(Ok("s3-shim.example.com"), [".."], "s3-shim.example.com")
    == router.NoRoute
}

pub fn virtual_host_label_must_be_valid_bucket_test() {
  // Single-character label is valid DNS but not a valid bucket name.
  assert router.route(Ok("a.s3-shim.example.com"), [], "s3-shim.example.com")
    == router.NoRoute
}

pub fn missing_host_falls_back_to_path_style_only_test() {
  // No Host header at all + virtual-host configured: only path-style works,
  // and only when the configured base host is empty (otherwise we fail).
  assert router.route(Error(Nil), ["bucket"], "")
    == router.BucketRoute(bucket: "bucket", remainder: [])

  assert router.route(Error(Nil), ["bucket"], "s3-shim.example.com")
    == router.NoRoute
}
