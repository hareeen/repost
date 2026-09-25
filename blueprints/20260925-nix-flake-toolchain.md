# Pin the toolchain and build the release image with a Nix flake

Base: 4d3be01a5376502a15277423f16f994a632d0212

Objective: one flake defines the Gleam/Erlang toolchain for the devShell, the git hooks, CI and the release image, so local and CI formatting can no longer disagree, and the image comes from a hermetic Nix build instead of the Dockerfile.

Scope: `flake.nix`, `flake.lock`, `nix/*.nix`, `.gitignore`, `.envrc`, `.git-blame-ignore-revs`, both workflows, README development/deploy sections, and a one-time reformat of `src/` and `test/`.
Out of scope: application code changes; a multi-arch image (today's workflow builds amd64 only, and parity is the goal).

Key assumptions:
- nixos-unstable ships Gleam 1.18.1, Erlang 28.5 and rebar3 3.27; the flake pins that nixpkgs and CI takes Gleam from it (was 1.15.4 via `setup-beam`).
- Every Hex dependency in `manifest.toml` carries an `outer_checksum` (SHA-256 of the Hex tarball), so each can be a fixed-output `beamPackages.fetchHex` derivation keyed by the lockfile, and `gleam export erlang-shipment` can then run offline.
- `mist`'s transitive rebar3 packages compile offline under Gleam with `rebar3` on `PATH` and a writable `HOME`.
- OTP's `public_key:cacerts_get()` reads `/etc/ssl/certs/ca-certificates.crt`, so the image must put the CA bundle there (not only set `SSL_CERT_FILE`).
- This Mac has no Linux builder, so the image (a Linux artifact) is built and checked only in CI; everything else is verified locally.

Checkpoints: after T3 (toolchain unified: devShell, hooks, reformat, CI) and after T6 (image workflow ready, Dockerfile still present). T7 waits for your go-ahead.

## Tasks

- [x] T0: Commit the pending work already in the tree, as two commits: the four review fixes (drop `sigv4.empty_sha256_hex`; make `r2.endpoint_parts`/`host_header_for` private; `binary:copy` the leftover in `upload/sink`; shared `r2.credentials` and `repost/xml` with `escape`), then the README/spec rewrite.
  - Files: `src/repost/**`, `test/sigv4_test.gleam`, `test/xml_test.gleam`, `README.md`, `spec.md`
  - Context: already verified (129 tests); this task only commits.

- [x] T1: Flake skeleton and devShell. `flake.nix` with flake-parts (`nixpkgs-lib.follows`), nixos-unstable, `treefmt-nix` and `git-hooks` following nixpkgs; systems `x86_64-linux`, `aarch64-linux`, `aarch64-darwin`. `devShells.default` has `gleam`, `erlang_28`, `rebar3` and the treefmt wrapper in `packages`, and gets the hooks through `inputsFrom = [config.pre-commit.devShell]`. treefmt: `projectRootFile = "flake.nix"`, `nixfmt`, and Gleam via `programs.gleam` if treefmt-nix has it, otherwise a `settings.formatter.gleam` running `gleam format` on `*.gleam`. Exclude `manifest.toml` and `LICENSE`. Hooks: `treefmt` at pre-commit (`package = config.treefmt.build.wrapper`); `statix`, `deadnix` and a custom `gleam build --warnings-as-errors` hook at pre-push. Track the existing `.envrc` (`use flake`); add `.direnv/` and `result*` to `.gitignore`.
  - Files: `flake.nix`, `flake.lock`, `.gitignore`, `.envrc`
  - Depends on: T0
  - Context: flakes only see git-tracked files, so `git add` new files before evaluating. `gleam format --check src test` will fail until T2; that is expected here.

- [x] T2: One-time reformat with the pinned formatter, as its own commit: `nix develop -c treefmt`. Then add that commit's hash to `.git-blame-ignore-revs` in a follow-up commit.
  - Files: `src/**/*.gleam`, `test/**/*.gleam`, `flake.nix`, `.git-blame-ignore-revs`
  - Depends on: T1
  - Context: formatting only. Confirm with `git diff --stat` that no Gleam file changes beyond whitespace/wrapping, and that the tests still pass.

- [x] T3: CI on the flake. `ci.yml` installs Nix (a maintained action, e.g. `cachix/install-nix-action`) and runs `nix flake check` (the hook checks), `nix develop -c treefmt --ci`, `nix develop -c gleam build --warnings-as-errors` and `nix develop -c gleam test`. Drop `erlef/setup-beam` and the Gleam 1.15.4 pin. Cache the Nix store only through a maintained action; if none fits, go without and say so.
  - Files: `.github/workflows/ci.yml`
  - Depends on: T2
  - Context: `treefmt --ci` fails on any diff, so CI and the pre-commit hook enforce the same formatter.

- [x] T4: Hermetic release package. `nix/gleam-deps.nix` reads `manifest.toml` with `builtins.fromTOML` and turns each `source = "hex"` package into `beamPackages.fetchHex { pkg; version; sha256 = outer_checksum; }`, assembling `build/packages/<name>` plus the `packages.toml` Gleam expects. `nix/package.nix` copies the cleaned source, links in the vendored packages, runs `gleam export erlang-shipment` offline (`strictDeps = true`, tools from `pkgs.buildPackages`), and installs the shipment plus a `bin/repost` wrapper (`makeWrapper`, Erlang on `PATH`, `entrypoint.sh run`). Expose it as `packages.default`; the devShell `inputsFrom` it.
  - Files: `nix/gleam-deps.nix`, `nix/package.nix`, `flake.nix`
  - Depends on: T1
  - Context: if Gleam insists on the network or re-resolves despite a matching manifest, stop and report; do not fall back to `--impure` or `builtins.getEnv`. A stale `manifest.toml` must fail the build loudly. Verify with `nix build .#default` locally (the shipment is BEAM bytecode and builds on Darwin), then run `result/bin/repost` with the env vars unset and confirm it exits naming the first missing variable.

- [x] T5: Release image. `nix/image.nix` uses `nix2container.buildImage` with a `copyToRoot` that links only `bin/repost` and the CA bundle at `/etc/ssl/certs/ca-certificates.crt`; `Entrypoint = ["/bin/repost"]`, `User = "65532:65532"`, `ExposedPorts."4000/tcp"`. Expose it as `packages.repost-image` on Linux systems only. Add the `nix2container` input with `inputs.nixpkgs.follows`.
  - Files: `nix/image.nix`, `flake.nix`, `flake.lock`
  - Depends on: T4
  - Context: can't be built on this Mac. Verify locally that `nix eval .#packages.x86_64-linux.repost-image.drvPath` evaluates; the real build is T6's CI run.

- [x] T6: Image workflow on the flake. `docker.yml` keeps the triggers and the `metadata-action` tags, but builds with `nix build .#repost-image` and pushes each tag with `nix run .#repost-image.copyTo -- docker://ghcr.io/<repo>:<tag>`, authenticating with `GITHUB_TOKEN`. Before pushing, CI loads the image with `copyToDockerDaemon`, starts it with a missing required env var, and asserts it exits naming the variable. README: replace "Quick start" Docker build with `nix build .#repost-image` (plus the pull-from-GHCR option), and add a "Development" note on `nix develop` / direnv and the hooks.
  - Files: `.github/workflows/docker.yml`, `README.md`
  - Depends on: T5, T3
  - Context: keep the Dockerfile in this task. The workflow can only be proven by a CI run, which needs a push, and pushing is your call.

- [x] T6b: Multi-arch, leaner, labelled image (revision agreed after T6; the Mac now has a nix-darwin `linux-builder` for aarch64-linux).
  - Runtime: build and run on `beam_minimal`'s Erlang 28 (both the same release), dropping wxwidgets/gettext/libtiff from the closure. The devShell keeps getting Erlang through `inputsFrom` the package. Report the closure size before and after.
  - Multi-arch per `~/.claude/rules/dev-environment.md`: on each Linux system expose `repost-image-amd64`, `repost-image-arm64` and `repost-image` (an OCI index made with `regctl index create`, following the rule's `nix/oci-index.nix` template). The image matching the host is built natively; the other one uses `import inputs.nixpkgs { localSystem = system; crossSystem = …; }` and the same `nix/package.nix`/`nix/image.nix` (the BEAM shipment is architecture-independent, so only the runtime closure differs).
  - Cross probe first: build `.#packages.aarch64-linux.repost-image-amd64` on the linux-builder. If cross-compiling Erlang fails, stop cross work and switch to the fallback: `docker.yml` builds each architecture natively in a matrix (`ubuntu-latest`, `ubuntu-24.04-arm`), pushes per-arch tags, then a final job merges them with `regctl index create`. Report which path was taken and why.
  - Labels: `org.opencontainers.image.source` (the GitHub repo URL) and `org.opencontainers.image.revision` (`self.rev`, or `self.dirtyRev` when dirty).
  - Linux check: `checks.<linux system>.launcher` runs the package's `bin/repost` with an empty environment and passes only if it exits non-zero naming `SHIM_ACCESS_KEY_ID`. Runs locally on the linux-builder and in CI through `nix flake check`.
  - `docker.yml`: smoke test the amd64 image in Docker as today, then push the index to every metadata tag (`regctl image copy ocidir://…` or `copyTo` per arch plus index, whichever keeps the token out of logs). `ci.yml`'s shipment job uploads only `result/lib/repost`.
  - README: multi-arch pull, and building locally through the linux-builder.
  - Files: `nix/package.nix`, `nix/image.nix`, `nix/oci-index.nix`, `flake.nix`, `flake.lock`, `.github/workflows/docker.yml`, `.github/workflows/ci.yml`, `README.md`
  - Outcome: cross-compiling Erlang failed in nixpkgs (`cross_check_erl`: no build-machine OTP, crypto/ssl disabled), so the native-matrix fallback shipped; image kept over the Dockerfile at 86.7 MB vs 58.6 MB (arm64).
  - Depends on: T6
  - Context: locally verifiable now: `nix build .#packages.aarch64-linux.repost-image-arm64`, the cross probe, `.#packages.aarch64-linux.repost-image`, and `nix build .#checks.aarch64-linux.launcher`. No Docker on this Mac, so the container smoke test and the x86_64-host builds are CI-only.

- [ ] T7: Remove `Dockerfile` and `.dockerignore`. **Gate: run only after you confirm T6's workflow passed in CI.**
  - Files: `Dockerfile`, `.dockerignore`, `README.md`
  - Depends on: T6

- [ ] T8: Acceptance. Confirm `setup-beam` and `1.15.4` appear nowhere; the devShell, CI and hooks all get Gleam from the same flake (`nix develop -c gleam --version` = 1.18.1); `nix flake check` passes; statix and deadnix are clean on `flake.nix` and `nix/`. Report what could only be verified in CI.
  - Depends on: T6 (and T7 if it ran)

## Verification
- L1 (each task): `nix flake check && nix develop -c gleam test` (T0–T2 before the flake exists: `gleam test`)
- L3 (final): `nix flake check && nix develop -c treefmt --ci && nix develop -c gleam build --warnings-as-errors && nix develop -c gleam test && nix build .#default`

## Rules
- These tasks need the network (flake inputs, `fetchHex`): run the executor with network access, and never hand-edit `flake.lock`.
- Nix files follow `~/.claude/rules/dev-environment.md`: flake-parts, every input `follows` nixpkgs, one file per artifact under `nix/`, no `builtins.getEnv`/`--impure`.
- The reformat (T2) never shares a commit with any other change.
- Don't push. T6 is verified by the push you choose to make; T7 waits for your go-ahead.
