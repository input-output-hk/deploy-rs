# SPDX-FileCopyrightText: 2020 Serokell <https://serokell.io/>
# SPDX-FileCopyrightText: 2020 Andreas Fuchs <asf@boinkor.net>
#
# SPDX-License-Identifier: MPL-2.0

{
  description = "A Simple multi-profile Nix-flake deploy tool.";

  inputs = {
    utils.url = "github:numtide/flake-utils";
    flake-compat = {
      url = "github:edolstra/flake-compat";
      flake = false;
    };
    fenix = {
      url = "github:nix-community/fenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixpkgs.url = "nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs, utils, fenix, ... }:
    let toolchain = "stable";
    in {
      overlay = final: prev:
        let
          system = final.system;
          darwinOptions = final.lib.optionalAttrs final.stdenv.isDarwin {
            buildInputs = with final.darwin.apple_sdk.frameworks; [
              SystemConfiguration
              CoreServices
            ];
          };
        in {
          deploy-rs = {

            deploy-rs = (final.makeRustPlatform {
              inherit (final.fenix.${toolchain}) cargo rustc;
            }).buildRustPackage (darwinOptions // {
              pname = "deploy-rs";
              version = "0.1.0";

              src = nixpkgs.lib.cleanSource ./.;

              cargoLock.lockFile = ./Cargo.lock;
            }) // {
              meta.description = "A Simple multi-profile Nix-flake deploy tool";
            };

            lib = rec {

              setActivate = builtins.trace
                "deploy-rs#lib.setActivate is deprecated, use activate.noop, activate.nixos or activate.custom instead"
                activate.custom;

              activate = rec {
                custom = {
                  __functor = customSelf: base: activate:
                    (final.buildEnv {
                      name = ("activatable-" + base.name);
                      paths = [
                        base
                        (final.writeTextFile {
                          name = base.name + "-activate-path";
                          text = ''
                            #!${final.runtimeShell}
                            set -euo pipefail

                            if [[ "''${DRY_ACTIVATE:-}" == "1" ]]
                            then
                                ${
                                  customSelf.dryActivate or "echo ${
                                    final.writeScript "activate" activate
                                  }"
                                }
                            else
                                ${activate}
                            fi
                          '';
                          executable = true;
                          destination = "/deploy-rs-activate";
                        })
                        (final.writeTextFile {
                          name = base.name + "-activate-rs";
                          text = ''
                            #!${final.runtimeShell}
                            exec ${
                              self.defaultPackage.${system}
                            }/bin/activate "$@"
                          '';
                          executable = true;
                          destination = "/activate-rs";
                        })
                      ];
                    } // customSelf);
                };

                nixos = base:
                  (custom // {
                    inherit base;
                    dryActivate =
                      "$PROFILE/bin/switch-to-configuration dry-activate";
                  }) base.config.system.build.toplevel ''
                    # work around https://github.com/NixOS/nixpkgs/issues/73404
                    cd /tmp

                    $PROFILE/bin/switch-to-configuration switch

                    # https://github.com/serokell/deploy-rs/issues/31
                    ${with base.config.boot.loader;
                    final.lib.optionalString systemd-boot.enable
                    "sed -i '/^default /d' ${efi.efiSysMountPoint}/loader/loader.conf"}
                  '';

                home-manager = base:
                  custom base.activationPackage "$PROFILE/activate";

                noop = base: custom base ":";
              };

              deployChecks = deploy:
                builtins.mapAttrs (_: check: check deploy) {
                  schema = deploy:
                    final.runCommandNoCC "jsonschema-deploy-system" { } ''
                      ${final.python3.pkgs.jsonschema}/bin/jsonschema -i ${
                        final.writeText "deploy.json" (builtins.toJSON deploy)
                      } ${self}/interface.json && touch $out
                    '';

                  activate = deploy:
                    let
                      profiles = builtins.concatLists (final.lib.mapAttrsToList
                        (nodeName: node:
                          final.lib.mapAttrsToList (profileName: profile: [
                            (toString profile.path)
                            nodeName
                            profileName
                          ]) node.profiles) deploy.nodes);
                    in final.runCommandNoCC "deploy-rs-check-activate" { } ''
                      for x in ${
                        builtins.concatStringsSep " "
                        (map (p: builtins.concatStringsSep ":" p) profiles)
                      }; do
                        profile_path=$(echo $x | cut -f1 -d:)
                        node_name=$(echo $x | cut -f2 -d:)
                        profile_name=$(echo $x | cut -f3 -d:)

                        test -f "$profile_path/deploy-rs-activate" || (echo "#$node_name.$profile_name is missing the deploy-rs-activate activation script" && exit 1);

                        test -f "$profile_path/activate-rs" || (echo "#$node_name.$profile_name is missing the activate-rs activation script" && exit 1);
                      done

                      touch $out
                    '';
                };
            };
          };
        };
    } // utils.lib.eachSystem (utils.lib.defaultSystems ++ [ "aarch64-darwin" ])
    (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ self.overlay fenix.overlay ];
        };
        rustPkg = pkgs.fenix.${toolchain}.withComponents [
          "cargo"
          "clippy"
          "rust-src"
          "rustc"
          "rustfmt"
        ];
      in {
        defaultPackage = self.packages."${system}".deploy-rs;
        packages.deploy-rs = pkgs.deploy-rs.deploy-rs;

        defaultApp = self.apps."${system}".deploy-rs;
        apps.deploy-rs = {
          type = "app";
          program = "${self.defaultPackage."${system}"}/bin/deploy";
        };

        devShell = pkgs.mkShell {
          RUST_SRC_PATH = "${rustPkg}/lib/rustlib/src/rust/library";
          buildInputs = with pkgs; [ rust-analyzer-nightly reuse rustPkg ];
        };

        checks = {
          deploy-rs = self.defaultPackage.${system}.overrideAttrs
            (super: { doCheck = true; });
        };

        lib = pkgs.deploy-rs.lib;
      });
}
