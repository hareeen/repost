# The repost Erlang shipment, built offline from the vendored Hex packages, plus a bin/repost launcher.
{
  # beam_minimal leaves out wxWidgets and the other GUI libraries a headless server never loads, which shrinks the Linux runtime closure several-fold.
  beamMinimal28Packages,
  buildPackages,
  callPackage,
  coreutils,
  lib,
  runtimeShell,
  source,
  stdenv,
}:
let
  config = builtins.fromTOML (builtins.readFile (source + "/gleam.toml"));
  deps = callPackage ./gleam-deps.nix {
    inherit source;
    beamPackages = beamMinimal28Packages;
  };
in
stdenv.mkDerivation {
  pname = config.name;
  inherit (config) version;

  src = lib.fileset.toSource {
    root = source;
    fileset = lib.fileset.unions [
      (source + "/gleam.toml")
      (source + "/manifest.toml")
      (source + "/src")
    ];
  };

  strictDeps = true;
  nativeBuildInputs = [
    buildPackages.beamMinimal28Packages.erlang
    buildPackages.beamMinimal28Packages.rebar3
    buildPackages.gleam
    buildPackages.makeWrapper
  ];

  buildPhase = ''
    runHook preBuild

    # rebar3 writes its cache under HOME while Gleam compiles the rebar3 dependencies.
    export HOME="$TMPDIR"
    # Gleam rewrites packages.toml and compiles rebar3 packages in place, so the vendored tree must be writable.
    mkdir -p build/packages
    cp -r --no-preserve=mode ${deps}/. build/packages/
    # Without `deterministic`, each .beam embeds the absolute path of the temporary build directory.
    ERL_COMPILER_OPTIONS=deterministic gleam export erlang-shipment

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/lib"
    cp -r build/erlang-shipment "$out/lib/${config.name}"
    # Gleam 1.18.1 writes the shipment's #!/bin/sh below a license header, where the kernel ignores it, so the launcher names the shell itself.
    # entrypoint.sh and Erlang's erl call dirname and basename, which a bare container does not provide.
    makeWrapper ${runtimeShell} "$out/bin/${config.name}" \
      --prefix PATH : ${
        lib.makeBinPath [
          coreutils
          beamMinimal28Packages.erlang
        ]
      } \
      --add-flags "$out/lib/${config.name}/entrypoint.sh run"

    runHook postInstall
  '';

  meta.mainProgram = config.name;
}
