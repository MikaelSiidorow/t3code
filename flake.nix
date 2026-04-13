{
  description = "T3 Code desktop app";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    systems.url = "github:nix-systems/default";
  };

  outputs =
    {
      self,
      nixpkgs,
      systems,
      ...
    }:
    let
      eachSystem = nixpkgs.lib.genAttrs (import systems);
      pkgsFor = system: import nixpkgs { inherit system; };
    in
    {
      packages = eachSystem (
        system:
        let
          pkgs = pkgsFor system;
          desktop = pkgs.callPackage ./nix/package.nix {
            src = self;
            commitHash = self.rev or "dirty";
          };
        in
        {
          default = desktop;
          t3code-desktop = desktop;
        }
      );

      devShells = eachSystem (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              bun
              nodejs_24
              electron_40
              jq
              python3
              nixfmt-tree
            ];
          };
        }
      );

      formatter = eachSystem (system: (pkgsFor system).nixfmt-tree);
    };
}
