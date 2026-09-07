{
  description = "zellij plugins";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    # nixpkgs' rustc ships no wasm32-wasip1 std, which zellij plugins need.
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs:
    inputs.flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      perSystem =
        { system, ... }:
        let
          pkgs = import inputs.nixpkgs {
            inherit system;
            overlays = [ inputs.rust-overlay.overlays.default ];
          };

          # Plugins are wasm, so the host platform is irrelevant beyond running
          # the compiler; every system builds the same artifact.
          rust = pkgs.rust-bin.stable.latest.minimal.override {
            targets = [ "wasm32-wasip1" ];
          };

          # zellij plugins are built with plain cargo rather than
          # buildRustPackage: the latter derives --target from the host
          # platform, and here the target is always wasm regardless of host.
          zellijPlugin =
            {
              pname,
              version,
              src,
              cargoLock,
              wasmName,
              meta ? { },
            }:
            pkgs.stdenv.mkDerivation {
              inherit pname version src meta;

              cargoDeps = pkgs.rustPlatform.importCargoLock { lockFile = cargoLock; };
              nativeBuildInputs = [
                rust
                pkgs.rustPlatform.cargoSetupHook
              ];

              buildPhase = ''
                runHook preBuild
                cargo build --release --offline --target wasm32-wasip1
                runHook postBuild
              '';

              installPhase = ''
                runHook preInstall
                install -Dm644 target/wasm32-wasip1/release/${wasmName} \
                  $out/bin/${wasmName}
                runHook postInstall
              '';

              # The output is wasm; there is nothing here for the usual fixups
              # to strip or patch.
              dontStrip = true;
              dontPatchELF = true;
            };
        in
        {
          packages.switch = zellijPlugin {
            pname = "zellij-switch";
            version = "0.1.0";
            src = pkgs.lib.cleanSource ./switch;
            cargoLock = ./switch/Cargo.lock;
            wasmName = "switch-zellij.wasm";
            meta = {
              description = "Zellij integration for switch: MRU tab and pane switching";
              platforms = pkgs.lib.platforms.all;
            };
          };

          packages.default = inputs.self.packages.${system}.switch;

          devShells.default = pkgs.mkShell {
            packages = [
              (pkgs.rust-bin.stable.latest.default.override {
                targets = [ "wasm32-wasip1" ];
                extensions = [
                  "rust-src"
                  "rust-analyzer"
                ];
              })
              pkgs.jq
            ];
            shellHook = ''
              echo "cargo build --release --target wasm32-wasip1"
            '';
          };
        };
    };
}
