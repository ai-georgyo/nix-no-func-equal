{
  description = "nix-eval-jobs built against upstream Nix and the no-function-pointer-equality fork";

  inputs = {
    # Used to build Nix and nix-eval-jobs.
    nixpkgs.url = "https://nixos.org/channels/nixpkgs-unstable/nixexprs.tar.xz";

    # The nixpkgs tree that the apps evaluate. Kept separate from `nixpkgs` so
    # it can be bumped (`nix flake update nixpkgs-eval`) without rebuilding Nix.
    nixpkgs-eval = {
      url = "github:glittershark/nixpkgs/no-function-pointer-equality";
      flake = false;
    };

    # Upstream Nix, pinned to the master commit the fork branches from so that
    # the only difference between the two builds is the fork's patch. Bump this
    # together with the fork (`git merge-base` of the two).
    nix-upstream = {
      url = "github:NixOS/nix/c621c2b3727700e439d4c3e5bff3ce5b35a24851";
      flake = false;
    };

    nix-fork = {
      url = "github:glittershark/nix/no-function-pointer-equality";
      flake = false;
    };

    nix-eval-jobs = {
      url = "github:nix-community/nix-eval-jobs/nix-next";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      nixpkgs-eval,
      nix-upstream,
      nix-fork,
      nix-eval-jobs,
    }:
    let
      inherit (nixpkgs) lib;

      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      eachSystem = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      # Build Nix's components from the given source using Nix's own packaging
      # (with its dependency overrides), and link nix-eval-jobs against them.
      mkScope =
        pkgs: nix:
        let
          packageSets =
            (import "${nix}/packaging/scopes.nix" {
              inherit lib;
              officialRelease = false;
              src = nix;
            }).packageSetsFor
              { inherit pkgs; };
        in
        {
          inherit (packageSets) nixComponents;
          nix-eval-jobs = packageSets.nixDependencies.callPackage "${nix-eval-jobs}/default.nix" {
            inherit (packageSets) nixComponents;
          };
        };

      variants = {
        upstream = nix-upstream;
        fork = nix-fork;
      };

      # Wrapper that runs nix-eval-jobs over nixpkgs' release.nix (what Hydra
      # evaluates). Any arguments replace the default job set, e.g.
      #   nix run .#eval-fork -- --expr '(import <nixpkgs> {}).hello'
      mkEvalApp =
        pkgs: name: nej:
        pkgs.writeShellApplication {
          name = "nix-eval-jobs-${name}-nixpkgs";
          runtimeInputs = [ nej ];
          text = ''
            nixpkgs="''${NIXPKGS:-${nixpkgs-eval}}"
            workers="''${WORKERS:-$(${pkgs.coreutils}/bin/nproc)}"
            max_memory="''${MAX_MEMORY_SIZE:-4096}"

            common=(
              --workers "$workers"
              --max-memory-size "$max_memory"
              --option allow-import-from-derivation false
              -I "nixpkgs=$nixpkgs"
            )

            if [ "$#" -eq 0 ]; then
              # release.nix maps every attribute (including recurseForDerivations)
              # to per-system sets, so recurse unconditionally like Hydra does.
              set -- \
                --force-recurse \
                --arg supportedSystems '[ "${pkgs.stdenv.hostPlatform.system}" ]' \
                "$nixpkgs/pkgs/top-level/release.nix"
            fi

            echo "nix-eval-jobs (${name}, Nix ${nej.passthru.nixComponents.nix-cli.version}) on $nixpkgs" >&2
            exec nix-eval-jobs "''${common[@]}" "$@"
          '';
        };
    in
    {
      packages = eachSystem (
        pkgs:
        let
          scopes = lib.mapAttrs (_: mkScope pkgs) variants;
        in
        {
          nix-upstream = scopes.upstream.nixComponents.nix-everything;
          nix-fork = scopes.fork.nixComponents.nix-everything;
          nix-eval-jobs-upstream = scopes.upstream.nix-eval-jobs;
          nix-eval-jobs-fork = scopes.fork.nix-eval-jobs;
        }
      );

      apps = eachSystem (
        pkgs:
        let
          p = self.packages.${pkgs.stdenv.hostPlatform.system};
          mkApp = name: nej: {
            type = "app";
            program = lib.getExe (mkEvalApp pkgs name nej);
          };
        in
        {
          eval-upstream = mkApp "upstream" p.nix-eval-jobs-upstream;
          eval-fork = mkApp "fork" p.nix-eval-jobs-fork;
        }
      );
    };
}
