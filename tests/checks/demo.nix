# `nix flake check` evaluates packages.* but never builds them; demo is the dogfooding artifact
# (nvimx's own env around tests/fixtures/basic-config), so build it here, where CI already runs.
{ pkgs, self, ... }:
self.packages.${pkgs.stdenv.hostPlatform.system}.demo
