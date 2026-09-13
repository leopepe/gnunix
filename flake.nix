{
  description = "GNUnix system package profiles";

  # Tracks tools/manifest.json .nix.channel; flake.lock fixes the revision and
  # Renovate (ADR-023) bumps it.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";

  outputs = { self, nixpkgs }:
    let
      # aarch64-linux only today. x86_64 is future work (ADR-010) and gets
      # added here, not abstracted for in advance.
      system = "aarch64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      profile = import ./nix/profile.nix pkgs;
    in
    {
      packages.${system} = {
        desktopProfile =
          profile "gnunix-desktop" (import ./nix/desktop.nix pkgs);

        installerProfile =
          profile "gnunix-installer" (import ./nix/installer.nix pkgs);

        installerBuildTools =
          profile "gnunix-installer-build-tools" (import ./nix/installer-build.nix pkgs);

        minimalProfile =
          profile "gnunix-minimal" (import ./nix/minimal.nix pkgs);
      };
    };
}
