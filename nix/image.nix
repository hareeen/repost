# The release OCI image: only the repost launcher, its store closure and the CA bundle.
{
  cacert,
  nix2container,
  package,
  runCommand,
}:
let
  name = package.pname;
  # OTP's public_key:cacerts_get() ignores SSL_CERT_FILE on Linux and reads fixed paths, the first being this Debian one.
  caBundle = "/etc/ssl/certs/ca-certificates.crt";
  root = runCommand "${name}-image-root" { } ''
    mkdir -p "$out/bin" "$out/etc/ssl/certs"
    ln -s ${package}/bin/${name} "$out/bin/${name}"
    ln -s ${cacert}/etc/ssl/certs/ca-bundle.crt "$out${caBundle}"
  '';
in
nix2container.buildImage {
  inherit name;
  copyToRoot = root;
  config = {
    Entrypoint = [ "/bin/${name}" ];
    User = "65532:65532";
    Env = [ "SSL_CERT_FILE=${caBundle}" ];
    ExposedPorts."4000/tcp" = { };
  };
}
