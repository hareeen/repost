{
  description = "repost";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    git-hooks = {
      url = "github:cachix/git-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      imports = [
        inputs.treefmt-nix.flakeModule
        inputs.git-hooks.flakeModule
      ];

      perSystem =
        {
          config,
          pkgs,
          ...
        }:
        {
          treefmt = {
            projectRootFile = "flake.nix";
            programs.nixfmt.enable = true;
            settings.formatter.gleam = {
              command = "${pkgs.gleam}/bin/gleam";
              options = [ "format" ];
              includes = [ "*.gleam" ];
            };
            settings.global.excludes = [
              "manifest.toml"
              "LICENSE"
            ];
          };

          pre-commit.settings.hooks = {
            treefmt = {
              enable = true;
              package = config.treefmt.build.wrapper;
            };

            statix = {
              enable = true;
              stages = [ "pre-push" ];
            };
            deadnix = {
              enable = true;
              stages = [ "pre-push" ];
            };
            # gleam build needs Hex deps already fetched into build/packages, which
            # the pre-commit sandbox (used by `nix flake check`) has no network
            # access to populate. Restrict this hook to the installed pre-push
            # hook, where the working tree's existing build/ dir is available.
            gleam-build = {
              enable = true;
              name = "gleam-build";
              entry = "${pkgs.gleam}/bin/gleam build --warnings-as-errors";
              language = "system";
              pass_filenames = false;
              stages = [ "pre-push" ];
            };
          };

          devShells.default = pkgs.mkShell {
            inputsFrom = [ config.pre-commit.devShell ];
            packages = [
              pkgs.gleam
              pkgs.erlang_28
              pkgs.rebar3
              config.treefmt.build.wrapper
            ];
          };
        };
    };
}
