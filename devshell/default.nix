{
  fenix-toolchain,
  fenix-channel,
  cargoArgs,
  commonArgs,
  unitTestArgs,
  flake-utils,
  pkgs,
  ...
}: let
  cargo-ext = pkgs.callPackage ./cargo-ext.nix {inherit cargoArgs unitTestArgs;};
in
  pkgs.mkShell rec {
    name = "Seeking-Edge-shell";

    buildInputs = commonArgs.buildInputs;
    nativeBuildInputs =
      commonArgs.nativeBuildInputs
      ++ (with pkgs;
        [
          cargo-ext.cargo-build-all
          cargo-ext.cargo-clippy-all
          cargo-ext.cargo-doc-all
          cargo-ext.cargo-nextest-all
          cargo-ext.cargo-test-all
          cargo-ext.cargo-udeps-all
          cargo-ext.cargo-watch-all
          cargo-nextest
          cargo-udeps
          cargo-watch
          cargo-audit
          cargo-outdated
          cargo-limit
          fenix-toolchain
          bacon
          bunyan-rs.out
          just
          nushell

          cocogitto

          nixpkgs-fmt
          shellcheck
          nodePackages.bash-language-server
        ]
        ++ builtins.attrValues {
          inherit (pkgs) cargo-nextest;
        });
    RUST_SRC_PATH = "${fenix-channel.rust-src}/lib/rustlib/src/rust/library";
    AMD_VULKAN_ICD = "RADV";

    LD_LIBRARY_PATH = "$LD_LIBRARY_PATH:${with pkgs;
      lib.makeLibraryPath [
        udev
        alsa-lib
        vulkan-loader
        libxkbcommon
        openssl
        wayland # To use wayland feature
      ]}";

    shellHook = ''
      cargo install puffin_viewer -q
      cargo install cargo-machete -q
      # cargo install cargo-nextest-q
      export EDITOR=hx
      # zellij session
      alias zj="zellij --layout dev-layout.kdl"

      SESSION="seeking-edge-dev"
      ZJ_SESSIONS=$(zellij list-sessions -n | rg 'seeking-edge-dev' ) #$SESSION )

       if [[ $ZJ_SESSIONS == *"seeking-edge-dev"* ]]; then
         exec zellij attach seeking-edge-dev options --default-layout ./dev-layout.kdl
       else
         exec zellij --session seeking-edge-dev --layout ./dev-layout.kdl
       fi
    '';
  }
