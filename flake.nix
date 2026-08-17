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

        # An OTP built with --enable-lock-counter, which adds a second emulator
        # alongside the normal one rather than replacing it: `erl` still runs
        # the ordinary smp emulator, and `erl -emu_type lcnt` runs the
        # instrumented one that :lcnt needs. Stock nixpkgs OTP is built without
        # it, so `erl -emu_type lcnt` reports "Available combinations are:
        # -emu_flavor smp" and :lcnt has nothing to collect from.
        #
        # This is not in the binary cache - changing configureFlags changes the
        # derivation hash - so the first `nix develop .#lcnt` builds OTP from
        # source. That is why it is a separate shell: ordinary work stays on the
        # cached toolchain in the default shell.
        erlangLcnt = beamPackages.erlang.overrideAttrs (old: {
          configureFlags = (old.configureFlags or [ ]) ++ [ "--enable-lock-counter" ];
        });

        beamLcntPackages = pkgs.beam.packagesWith erlangLcnt;

        commonPackages = [
          pkgs.rustc
          pkgs.cargo
        ];
      in
      {
        devShells.default = pkgs.mkShell {
          packages = [
            beamPackages.erlang
            beamPackages.elixir_1_20
          ] ++ commonPackages;
        };

        # Profiling shell. Use for lock-contention work:
        #
        #   nix develop .#lcnt
        #   ERL_FLAGS="-emu_type lcnt" mix run scripts/whatever.exs
        #
        # and inside the VM: :lcnt.start(), :lcnt.clear(), <workload>,
        # :lcnt.collect(), :lcnt.conflicts().
        #
        # Elixir is rebuilt against the instrumented OTP so the two cannot
        # drift apart. `_build` compiled by the default shell is reusable -
        # same OTP version, only a different emulator build - but if you hit
        # anything odd, `mix clean` is the cheap first move.
        devShells.lcnt = pkgs.mkShell {
          packages = [
            erlangLcnt
            beamLcntPackages.elixir_1_20
          ] ++ commonPackages;

          shellHook = ''
            echo "lock-counting OTP: run the VM with ERL_FLAGS=\"-emu_type lcnt\""
          '';
        };
      }
    );
}
