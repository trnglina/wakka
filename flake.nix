{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      nixpkgs,
      flake-utils,
      rust-overlay,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        overlays = [ (import rust-overlay) ];
        pkgs = import nixpkgs { inherit system overlays; };

        rust = pkgs.rust-bin.stable.latest.default;

        swi-prolog = pkgs.stdenv.mkDerivation {
          name = "swi-prolog";

          src = pkgs.fetchFromGitHub {
            owner = "SWI-Prolog";
            repo = "swipl";
            tag = "V10.0.2";
            hash = "sha256-w9BzcnXS2sqHsLXYEcfhZ1niKpifffiDtm8EcJ6cG9g=";
            fetchSubmodules = true;
          };

          postPatch = ''
            # Add the packInstall path to the swipl pack search path
            echo "user:file_search_path(pack, '$out/lib/swipl/extra-pack')." >> boot/init.pl

            # iconutil is unavailable, replace with png2icns from libicns
            substituteInPlace desktop/make_icns.sh \
              --replace-fail 'iconutil -c icns "$ICONSET_DIR" -o "$OUTPUT"' 'png2icns "$OUTPUT" "$INPUT"'
          '';

          nativeBuildInputs = [
            pkgs.cmake
            pkgs.ninja
          ]
          ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isDarwin [
            pkgs.libicns
          ];

          buildInputs = [
            pkgs.gmp
            pkgs.gperftools
            pkgs.libedit
            pkgs.libxcrypt
            pkgs.openssl
            pkgs.pcre2
            pkgs.zlib
          ];

          hardeningDisable = [ "format" ];

          cmakeFlags = [
            "-DINSTALL_TESTS=ON"
            "-DINSTALL_DOCUMENTATION=OFF"
            "-DSWIPL_INSTALL_IN_LIB=ON"
          ];
        };
      in
      {
        devShells.default = pkgs.mkShell {
          buildInputs = [
            rust
            swi-prolog

            pkgs.fontconfig
            pkgs.pkg-config
            pkgs.rustPlatform.bindgenHook
          ];
        };
      }
    );
}
