# SPDX-License-Identifier: MIT
{ closure-lib, ... }:
{
  config,
  inputs,
  lib,
  ...
}:
{

  imports = [
    inputs.flake-parts.flakeModules.partitions
    closure-lib.caisson.modules.flake."purifier/purifier-packages"
  ];

  # The package overlay registry (pkg-overlays/) has the `default` entry,
  # which adds the scope `pkgs.deno-purifier`. The package set applies it by
  # default, and the flake exports it as `pkgOverlays` and as the plain
  # `overlays.default`. The module from the purifier library publishes the
  # derivations of that scope as the packages of the flake.
  purifier.scope = "deno-purifier";

  debug = false;
  caisson.libOverlays.exported = libOverlays: {
    inherit (libOverlays) default;
  };

  # `nix run github:nix-purifiers/deno-purifier -- lock` records a project's
  # downloads. `nix develop github:nix-purifiers/deno-purifier` gives a shell
  # with `deno-purifier`, and with `deno` wrapped to read the locked
  # downloads from the Nix store.
  perSystem =
    { pkgs, ... }:
    {
      packages.default = pkgs.deno-purifier.deno-purifier;
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
