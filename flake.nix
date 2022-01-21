{
  description = "A very basic flake";
  nixConfig = {
    allow-import-from-derivation = "true";
    substituters = [ "https://mina-demo.cachix.org" "https://cache.nixos.org" ];
    trusted-public-keys = [
      "mina-demo.cachix.org-1:6Rttr65zJT5Fzndtu71WdInF6FnxKCU7KLtcQdWU4Ok="
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
    ];
  };

  inputs.utils.url = "github:gytis-ivaskevicius/flake-utils-plus";
  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable-small";

  # todo: upstream
  inputs.mix-to-nix.url = "github:serokell/mix-to-nix/yorickvp/deadlock";
  inputs.nix-npm-buildPackage.url =
    "github:lumiguide/nix-npm-buildpackage"; # todo: upstream
  inputs.opam-nix.url = "github:tweag/opam-nix";
  inputs.opam-nix.inputs.nixpkgs.follows = "nixpkgs";
  inputs.opam-nix.inputs.opam-repository.follows = "opam-repository";

  inputs.opam-repository.url = "github:ocaml/opam-repository";
  inputs.opam-repository.flake = false;

  inputs.nixpkgs-mozilla.url = "github:mozilla/nixpkgs-mozilla";
  inputs.nixpkgs-mozilla.flake = false;

  # For nix/compat.nix
  inputs.flake-compat.url = "github:edolstra/flake-compat";
  inputs.flake-compat.flake = false;
  inputs.gitignore-nix.url = "github:hercules-ci/gitignore.nix";
  inputs.gitignore-nix.inputs.nixpkgs.follows = "nixpkgs";

  outputs = inputs@{ self, nixpkgs, utils, mix-to-nix, nix-npm-buildPackage
    , opam-nix, opam-repository, nixpkgs-mozilla, ... }:
    let inherit (utils.lib) exportOverlays exportPackages;
    in utils.lib.mkFlake {
      inherit self inputs;
      supportedSystems = [ "x86_64-linux" ];
      channelsConfig.allowUnfree = true;
      #sharedOverlays = [ mix-to-nix.overlay ];
      sharedOverlays = [ (import nixpkgs-mozilla) self.overlay ];
      overlays = exportOverlays { inherit (self) pkgs inputs; };
      overlay = import ./nix/overlay.nix;
      outputsBuilder = channels:
        let
          pkgs = channels.nixpkgs;
          inherit (pkgs) lib;
          mix-to-nix = pkgs.callPackage inputs.mix-to-nix { };
          nix-npm-buildPackage =
            pkgs.callPackage inputs.nix-npm-buildPackage { };

          submodules = map builtins.head (builtins.filter lib.isList
            (map (builtins.match "	path = (.*)")
              (lib.splitString "\n" (builtins.readFile ./.gitmodules))));

          requireSubmodules = lib.warnIf (!builtins.all builtins.pathExists
            (map (x: ./. + "/${x}") submodules)) ''
              Some submodules are missing, you may get errors. Consider one of the following:
              - run nix/pin.sh and use "mina" flake ref;
              - use "git+file://$PWD?submodules=1";
              - use "git+https://github.com/minaprotocol/mina?submodules=1";
              - use non-flake commands like nix-build and nix-shell.
            '';

          checks = import ./nix/checks.nix inputs pkgs;

          ocamlPackages_static = requireSubmodules (import ./nix/ocaml.nix {
            inherit inputs pkgs;
            static = true;
          });

          ocamlPackages =
            requireSubmodules (import ./nix/ocaml.nix { inherit inputs pkgs; });
        in {

          # Jobs/Lint/Rust.dhall
          packages.trace-tool =
            channels.nixpkgs.rustPlatform.buildRustPackage rec {
              pname = "trace-tool";
              version = "0.1.0";
              src = ./src/app/trace-tool;
              cargoLock.lockFile = ./src/app/trace-tool/Cargo.lock;
            };

          # Jobs/Lint/ValidationService
          # Jobs/Test/ValidationService
          packages.validation = ((mix-to-nix.override {
            beamPackages = pkgs.beam.packagesWith pkgs.erlangR22; # todo: jose
          }).mixToNix {
            src = ./src/app/validation;
            # todo: think about fixhexdep overlay
            # todo: dialyze
            overlay = (final: previous: {
              goth = previous.goth.overrideAttrs (o: {
                preConfigure = "sed -i '/warnings_as_errors/d' mix.exs";
              });
            });
          }).overrideAttrs (o: {
            # workaround for requiring --allow-import-from-derivation
            # during 'nix flake show'
            name = "coda_validation-0.1.0";
            version = "0.1.0";
          });

          # Jobs/Release/LeaderboardArtifact
          packages.leaderboard = nix-npm-buildPackage.buildYarnPackage {
            src = ./frontend/leaderboard;
            yarnBuildMore = "yarn build";
            # fix reason
            yarnPostLink = pkgs.writeScript "yarn-post-link" ''
              #!${pkgs.stdenv.shell}
              ls node_modules/bs-platform/lib/*.linux
              patchelf \
                --set-interpreter "$(cat $NIX_CC/nix-support/dynamic-linker)" \
                --set-rpath "${pkgs.stdenv.cc.cc.lib}/lib" \
                ./node_modules/bs-platform/lib/*.linux ./node_modules/bs-platform/vendor/ninja/snapshot/*.linux
            '';
            # todo: external stdlib @rescript/std
            preInstall = ''
              shopt -s extglob
              rm -rf node_modules/bs-platform/lib/!(js)
              rm -rf node_modules/bs-platform/!(lib)
              rm -rf yarn-cache
            '';
          };

          inherit ocamlPackages ocamlPackages_static;
          packages.mina = ocamlPackages.mina;
          packages.mina-docker = pkgs.dockerTools.buildImage {
            name = "mina";
            contents = [ ocamlPackages.mina ];
          };
          packages.mina_static = ocamlPackages_static.mina;
          packages.marlin_plonk_bindings_stubs =
            pkgs.marlin_plonk_bindings_stubs;
          packages.go-capnproto2 = pkgs.go-capnproto2;
          packages.libp2p_helper = pkgs.libp2p_helper;
          packages.marlin_plonk_bindings_stubs_static =
            pkgs.pkgsMusl.marlin_plonk_bindings_stubs;

          legacyPackages.musl = pkgs.pkgsMusl;
          legacyPackages.regular = pkgs;

          defaultPackage = ocamlPackages.mina;

          packages.impure-shell = import ./nix/impure-shell.nix pkgs;
          devShells.impure = import ./nix/impure-shell.nix pkgs;

          inherit checks;
        };
    };
}