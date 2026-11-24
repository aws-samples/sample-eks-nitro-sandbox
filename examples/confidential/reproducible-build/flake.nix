{
  description = "Reproducible build of the reproducible-build sample's decrypt service image";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nix2container.url = "github:nlewo/nix2container";
    nix2container.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    { nixpkgs, nix2container, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      inherit (pkgs) lib;
      n2c = nix2container.packages.${system}.nix2container;

      server = pkgs.rustPlatform.buildRustPackage {
        pname = "reproducible-build-decrypt";
        version = "1";
        # Only the files cargo reads. A plain ./src would take every file in the folder, so a
        # .DS_Store or a stray target/ on one machine would change the source hash and with
        # it the image digest.
        src = lib.fileset.toSource {
          root = ./src;
          fileset = lib.fileset.unions [
            ./src/Cargo.toml
            ./src/Cargo.lock
            (lib.fileset.fileFilter (file: file.hasExt "rs") ./src/src)
          ];
        };
        cargoLock = {
          lockFile = ./src/Cargo.lock;
          outputHashes."cms-0.3.0-rc.2" = "sha256-BvAmuj4hbUA96RYzs58Q16+btQ9agJQHqyiixzz9VTU=";
        };
        # The builder runs with sandbox = false, so Nix builds in a randomly named directory
        # (/nix/var/nix/builds/nix-<pid>-<random>), and rustc embeds the source paths under it,
        # the vendored crates' included, in the binary for panic messages. Remapping it to a
        # fixed /build keeps the binary, and with it the image digest, the same on every build.
        # The vendor directory and CARGO_HOME both sit under NIX_BUILD_TOP.
        preBuild = ''
          export RUSTFLAGS="--remap-path-prefix=$NIX_BUILD_TOP=/build"
        '';
        doCheck = true;
      };

      # No created timestamp, so nix2container writes epoch 1, and no latest tag.
      # debug adds busybox (a shell and coreutils) and nothing else, so the difference
      # between the two images is one store path in copyToRoot and one PATH entry.
      mkImage =
        {
          debug ? false,
        }:
        let
          roots = [ pkgs.cacert ] ++ pkgs.lib.optional debug pkgs.busybox;
        in
        # The production image holds no shell: anything beyond the CA bundle fails eval.
        assert debug || roots == [ pkgs.cacert ];
        n2c.buildImage {
          name = "reproducible-build";
          tag = if debug then "v1-debug" else "v1";
          copyToRoot = roots;
          config = {
            Entrypoint = [ "${server}/bin/reproducible-build-decrypt" ];
            User = "65534:65534";
            # PATH is set so containerd keeps it instead of adding its default, which the
            # policy generator does not predict: the pinned env names would not match.
            Env = [
              "PATH=${server}/bin${pkgs.lib.optionalString debug ":/bin"}"
              # The copy copyToRoot puts in the image. The cacert store path itself is not
              # in the image, so pointing there leaves TLS with no roots (UnknownIssuer).
              "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
            ];
            ExposedPorts."8080/tcp" = { };
          };
        };
      image = mkImage { };
      image-debug = mkImage { debug = true; };
    in
    {
      packages.${system} = { inherit server image image-debug; };
      checks.${system} = { inherit server; };
    };
}
