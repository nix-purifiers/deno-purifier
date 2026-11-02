# SPDX-License-Identifier: MIT
{
  inputs.caisson.url = "github:nix-caisson/caisson";
  inputs.flake-parts.url = "github:hercules-ci/flake-parts";
  # Same channel as the main flake, so dev-partition evals agree with the
  # exported pkgSet.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  inputs.treefmt-nix.url = "github:numtide/treefmt-nix";
  inputs.treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";
  # A real-world Deno project the checks build: deployctl, the command-line
  # tool of Deno Deploy, at a pinned commit. tests/real/deployctl holds the
  # lockfiles for it.
  inputs.deployctl.url = "github:denoland/deployctl/87e43e57b2336bcaf96bcd193687edcb3c5795c1";
  inputs.deployctl.flake = false;
  outputs = { ... }: { };
}
