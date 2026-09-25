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
    nix2container = {
      url = "github:nlewo/nix2container";
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
          lib,
          pkgs,
          self',
          system,
          ...
        }:
        let
          inherit (pkgs.stdenv.hostPlatform) isLinux;
        in
        {
          packages = {
            default = pkgs.callPackage ./nix/package.nix { source = ./.; };
          }
          # Images are Linux artifacts; Darwin systems get no image output rather than a broken one.
          # nixpkgs cannot cross-compile Erlang (its build finds no Erlang for the build machine), so each Linux system builds only its own architecture and CI merges the two into one index.
          // lib.optionalAttrs isLinux {
            # nix2container tags the image with the same GOARCH, so the output name and the image platform agree.
            "repost-image-${pkgs.go.GOARCH}" = pkgs.callPackage ./nix/image.nix {
              inherit (inputs.nix2container.packages.${system}) nix2container;
              package = self'.packages.default;
              repository = "https://github.com/hareeen/repost";
              revision = inputs.self.rev or inputs.self.dirtyRev;
            };
          };

          checks = lib.optionalAttrs isLinux {
            launcher = pkgs.runCommand "repost-launcher-check" { } ''
              if output=$(env -i ${lib.getExe self'.packages.default} 2>&1); then
                echo "$output"
                echo "expected the launcher to exit non-zero without configuration" >&2
                exit 1
              fi
              echo "$output"
              grep -q SHIM_ACCESS_KEY_ID <<<"$output"
              touch "$out"
            '';
          };

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
            # gleam build needs Hex deps in build/packages, which the `nix flake check` sandbox cannot fetch.
            # Only the installed pre-push hook runs it, against the working tree's existing build/.
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
            inputsFrom = [
              config.pre-commit.devShell
              self'.packages.default
            ];
            packages = [ config.treefmt.build.wrapper ];
          };
        };
    };
}
