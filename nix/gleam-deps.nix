# Vendors the Hex packages locked in manifest.toml into the build/packages layout Gleam treats as already downloaded.
{
  beamPackages,
  lib,
  runCommand,
  source,
}:
let
  manifest = builtins.fromTOML (builtins.readFile (source + "/manifest.toml"));
  config = builtins.fromTOML (builtins.readFile (source + "/gleam.toml"));

  # Gleam re-resolves (and so reaches for the network) whenever the manifest's requirements differ from gleam.toml's.
  # Checking the same condition here turns a stale manifest into an evaluation error instead of a build that depends on the network, even where the Nix sandbox is off.
  normalizeRequirement =
    requirement: if builtins.isString requirement then { version = requirement; } else requirement;
  configRequirements = lib.mapAttrs (_: normalizeRequirement) (
    config.dependencies or { } // config.dev_dependencies or { }
  );

  fetchPackage =
    package:
    if package.source == "hex" then
      beamPackages.fetchHex {
        pkg = package.name;
        inherit (package) version;
        sha256 = package.outer_checksum;
      }
    else
      throw "manifest.toml: ${package.name} has source \"${package.source}\"; only Hex packages can be vendored";

  # Gleam skips the download of every package whose name and version appear in build/packages/packages.toml.
  packagesToml = lib.concatMapStrings (package: ''
    ${package.name} = "${package.version}"
  '') manifest.packages;

  copyPackages = lib.concatMapStrings (package: ''
    cp -r ${fetchPackage package} "$out/${package.name}"
  '') manifest.packages;
in
assert lib.assertMsg (manifest.requirements == configRequirements)
  "manifest.toml is stale: its [requirements] differ from gleam.toml's dependencies; run `gleam deps download` and commit manifest.toml";
runCommand "${config.name}-gleam-deps" { } ''
  mkdir "$out"
  ${copyPackages}
  cat > "$out/packages.toml" <<'TOML'
  [packages]
  ${packagesToml}
  TOML
''
