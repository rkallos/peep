{
  description = "peep development environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };
        beamPackages = pkgs.beam29Packages;
      in
      {
        devShells.default = pkgs.mkShell {
          packages = [
            beamPackages.erlang
            beamPackages.elixir_1_20
            pkgs.rustc
            pkgs.cargo
          ];
        };
      }
    );
}
