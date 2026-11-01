# SPDX-License-Identifier: MIT
{ ... }:
{
  config,
  inputs,
  lib,
  ...
}:
{

  imports = [ inputs.flake-parts.flakeModules.partitions ];

  debug = false;
  caisson = {
    libOverlays.exported = libOverlays: {
      inherit (libOverlays) default;
    };

    # The package overlay registry (pkg-overlays/) has the `default` entry,
    # which adds the scope `pkgs.deno-purifier`. The package set applies it
    # by default, and the flake exports it as `pkgOverlays` and as the plain
    # `overlays.default`. The scope holds the builder, a function, so the
    # flake names the packages it exports below.
    nixpkgs = {
      packages.export.enabled = false;
    };
  };

  # `nix run github:nix-purifiers/deno-purifier -- lock` records a project's
  # downloads. `nix develop github:nix-purifiers/deno-purifier` gives a shell
  # with `deno-purifier`, and with `deno` wrapped to read the locked
  # downloads from the Nix store.
  perSystem =
    { pkgs, ... }:
    {
      packages = pkgs.lib.filterAttrs (_: pkgs.lib.isDerivation) pkgs.deno-purifier // {
        default = pkgs.deno-purifier.deno-purifier;
      };
      devShells.default = pkgs.mkShell {
        packages = [ pkgs.deno-purifier.deno-purifier ];
      };
    };

  partitionedAttrs.checks = "checks";
  partitionedAttrs.formatter = "formatter";

  partitions.formatter = {
    extraInputs = (lib.caisson.pins.flake-compat ../../../tests/dependencies).sources;
    module =
      { inputs, ... }:
      {
        imports = [ inputs.treefmt-nix.flakeModule ];
        perSystem.treefmt.programs.nixfmt.enable = true;
      };
  };

  partitions.checks = {
    extraInputs = (lib.caisson.pins.flake-compat ../../../tests/dependencies).sources;
    module =
      { inputs, self, ... }:
      {
        imports = [ inputs.treefmt-nix.flakeModule ];
        perSystem =
          { pkgs, ... }:
          {
            checks = import ../../../tests {
              inherit pkgs lib;
              inherit (inputs) deployctl;
              overlay = self.overlays.default;
            };
            treefmt.programs.nixfmt.enable = true;
          };
      };
  };

}
