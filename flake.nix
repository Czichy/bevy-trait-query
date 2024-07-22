{
  description = "Seeking Edge";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    crane.url = "github:ipetkov/crane";
    crane.inputs.nixpkgs.follows = "nixpkgs";
    flake-utils.url = "github:numtide/flake-utils";
    fenix = {
      url = "github:nix-community/fenix/monthly";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    flake-compat = {
      url = "github:edolstra/flake-compat";
      flake = false;
    };
    devshell = {
      url = "github:numtide/devshell";
      inputs = {
        flake-utils.follows = "flake-utils";
        nixpkgs.follows = "nixpkgs";
      };
    };
  };

  outputs = {
    self,
    nixpkgs,
    flake-utils,
    flake-compat,
    fenix,
    crane,
    devshell,
  }:
    flake-utils.lib.eachDefaultSystem (system: let
      pkgs = import nixpkgs {
        inherit system;
        overlays = [
          #   (
          #     final: prev: {
          #       # Note: shell script adding DYLD_FALLBACK_LIBRARY_PATH because of: https://github.com/nextest-rs/nextest/issues/962
          #       cargo-nextest = pkgs.writeShellScriptBin "cargo-nextest" "exec env DYLD_FALLBACK_LIBRARY_PATH=\"$(dirname $(${pkgs.which}/bin/which rustc))/../lib\" ${prev.cargo-nextest}/bin/cargo-nextest \"$@\"";
          #     }
          #   )
          devshell.overlays.default
          fenix.overlays.default
        ];
      };

      lib = pkgs.lib;

      fenix-channel = fenix.packages.${system}.complete;

      fenix-toolchain = fenix-channel.withComponents [
        "rustc"
        "cargo"
        "clippy"
        "rust-analysis"
        "rust-analyzer"
        "rust-src"
        "rustfmt"
        "llvm-tools-preview"
      ];

      craneLib = crane.lib.${system}.overrideToolchain fenix-toolchain;

      # filter source code at path `src` to include only the list of `modules`
      filterModules = modules: src: let
        basePath = toString src + "/";
      in
        lib.cleanSourceWith {
          filter = path: type: let
            relPath = lib.removePrefix basePath (toString path);
            includePath =
              (type
                == "directory"
                && builtins.match "^[^/]+$" relPath != null)
              || lib.any (re: builtins.match re relPath != null)
              (["Cargo.lock" "Cargo.toml" ".*/Cargo.toml"]
                ++ builtins.concatLists
                (map (name: [name "${name}/.*"]) modules));
            # uncomment to debug:
          in
            builtins.trace "${relPath}: ${lib.boolToString includePath}"
            includePath;
          inherit src;
        };

      # Filter only files needed to build project dependencies
      #
      # To get good build times it's vitally important to not have to
      # rebuild derivation needlessly. The way Nix caches things
      # is very simple: if any input file changed, derivation needs to
      # be rebuild.
      #
      # For this reason this filter function strips the `src` from
      # any files that are not relevant to the build.
      #
      # Lile `filterWorkspaceFiles` but doesn't even need *.rs files
      # (because they are not used for building dependencies)
      filterWorkspaceDepsBuildFiles = src:
        filterSrcWithRegexes ["Cargo.lock" "Cargo.toml" ".*/Cargo.toml"]
        src;

      # Filter only files relevant to building the workspace
      filterWorkspaceFiles = src:
        filterSrcWithRegexes [
          "Cargo.lock"
          "Cargo.toml"
          ".*/Cargo.toml"
          ".*.rs"
          ".*/rc/doc/.*.md"
          ".*.txt"
        ]
        src;

      filterSrcWithRegexes = regexes: src: let
        basePath = toString src + "/";
      in
        lib.cleanSourceWith {
          filter = path: type: let
            relPath = lib.removePrefix basePath (toString path);
            includePath =
              (type == "directory")
              || lib.any (re: builtins.match re relPath != null) regexes;
            # uncomment to debug:
          in
            builtins.trace "${relPath}: ${lib.boolToString includePath}"
            includePath;
          inherit src;
        };
      # Combine the environment and other configuration needed for crane to build our Rust packages
      commonArgs = {
        src = filterWorkspaceFiles ./.;

        buildInputs = with pkgs; [
          # fenix-channel.rustc
          # fenix-channel.clippy
          clang
          mold
          lld
          flatbuffers

          pkg-config
          gtk3
          openssl
          atk
          alsaLib
          udev
          vulkan-tools
          vulkan-loader
          vulkan-headers
          amdvlk
          glibc
          glib
          vulkan-validation-layers
          xorg.libX11
          xorg.libXcursor
          xorg.libXrandr
          xorg.libXi # To use x11 feature
          libxkbcommon
          wayland
        ];

        nativeBuildInputs = with pkgs; [
          alsa-lib
          libxkbcommon
          openssl
          pkg-config
          udev
          vulkan-loader
        ];

        LIBCLANG_PATH = "${pkgs.libclang.lib}/lib/";
        CI = "true";
        HOME = "/tmp";
        # We enable backtraces on any failure for help with debugging
        RUST_BACKTRACE = "1";
      };
      workspaceDeps = craneLib.buildDepsOnly (commonArgs
        // {
          src = filterWorkspaceDepsBuildFiles ./.;
          pname = "workspace-deps";
          buildPhaseCargoCommand = "cargo doc && cargo check --profile release --all-targets && cargo build --profile release --all-targets";
          doCheck = false;
        });

      # a function to define cargo&nix package, listing
      # all the dependencies (as dir) to help limit the
      # amount of things that need to rebuild when some
      # file change
      pkg = {
        name ? null,
        dir,
        port ? 8000,
        extraDirs ? [],
      }: rec {
        package = craneLib.buildPackage (commonArgs
          // {
            cargoArtifacts = workspaceDeps;

            src = filterModules ([dir] ++ extraDirs) ./.;

            # if needed we will check the whole workspace at once with `workspaceBuild`
            doCheck = false;
          }
          // lib.optionalAttrs (name != null) {
            pname = name;
            cargoExtraArgs = "--bin ${name}";
          });
      };

      workspaceBuild = craneLib.cargoBuild (commonArgs
        // {
          pname = "workspace-build";
          cargoArtifacts = workspaceDeps;
          doCheck = false;
        });

      workspaceTest = craneLib.cargoBuild (commonArgs
        // {
          pname = "workspace-test";
          cargoArtifacts = workspaceBuild;
          doCheck = true;
        });

      # Note: can't use `cargoClippy` because it implies `--all-targets`, while
      # we can't build benches on stable
      # See: https://github.com/ipetkov/crane/issues/64
      workspaceClippy = craneLib.cargoBuild (commonArgs
        // {
          pname = "workspace-clippy";
          cargoArtifacts = workspaceBuild;

          cargoBuildCommand = "cargo clippy --profile release --no-deps --lib --bins --tests --examples --workspace -- --deny warnings";
          doInstallCargoArtifacts = false;
          doCheck = false;
        });

      workspaceDoc = craneLib.cargoBuild (commonArgs
        // {
          pname = "workspace-doc";
          cargoArtifacts = workspaceBuild;
          cargoBuildCommand = "env RUSTDOCFLAGS='-D rustdoc::broken_intra_doc_links' cargo doc --no-deps --document-private-items && cp -a target/doc $out";
          doCheck = false;
        });

      seeking-edge = pkg {
        name = "seeking-edge";
        dir = "seeking-edge";
        extraDirs = [
          "seeking-edge"
          "se-app"
          "se-ui"
          "bevy_ibkr_client"
          "candle"
          "ibkr"
          "market_data"
          "se_account"
          "se_bevy_utils"
          "se_utils"
          "se_identifier"
          "se_instrument"
          "se_orders"
          "se_time"
          "snapshot"
          "statistics"
          "test_helpers"
        ];
      };

      cargoArgs = [
        "--workspace"
        "--bins"
        "--examples"
        "--tests"
        "--benches"
        "--all-targets"
      ];

      unitTestArgs = ["--workspace"];
    in {
      packages = {
        default = seeking-edge.package;
        seeking-edge = seeking-edge.package;

        deps = workspaceDeps;
        workspaceBuild = workspaceBuild;
        workspaceClippy = workspaceClippy;
        workspaceTest = workspaceTest;
        workspaceDoc = workspaceDoc;

        container = {seeking-edge = seeking-edge.container;};
      };

      # `nix develop`
      devShells.default = pkgs.callPackage ./devshell {
        inherit
          fenix-toolchain
          fenix-channel
          cargoArgs
          commonArgs
          unitTestArgs
          flake-utils
          ;
      };
    });
}
