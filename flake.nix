{
  description = "AI-assisted file renaming and rollback with Bend";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs = { self, nixpkgs }:
    let
      platforms = {
        x86_64-linux = {
          target = "linux-x64";
          sha256 = "c9ff8d67bd903fb6ad9a26b43d8a62c01021de82a44d55ce4a3dcd4732113d6b";
        };
        aarch64-linux = {
          target = "linux-arm64";
          sha256 = "2f42a6fa34ecdaa71ae105e5fa734f9a07e129d333e45448ab6d2ff03a837570";
        };
      };
      eachPlatform = f: builtins.mapAttrs (system: platform: f nixpkgs.legacyPackages.${system} platform) platforms;
      bendVersion = "2.0.40";
      locked = builtins.fromJSON (builtins.readFile ./nix/bend-deps.json);
      bendFor = pkgs: platform: pkgs.stdenv.mkDerivation {
        pname = "bend-compiler";
        version = bendVersion;
        src = pkgs.fetchurl {
          url = "https://github.com/bendlang/bend/releases/download/v${bendVersion}/bend-${bendVersion}-${platform.target}.tar.gz";
          inherit (platform) sha256;
        };
        nativeBuildInputs = [ pkgs.autoPatchelfHook pkgs.makeWrapper ];
        buildInputs = [ pkgs.stdenv.cc.cc.lib ];
        dontBuild = true;
        installPhase = ''
          runHook preInstall
          mkdir -p "$out"
          cp -R bin bend2 guide "$out/"
          wrapProgram "$out/bin/bend" --set-default BEND_HOME "$out" --set-default BEND_NO_TELEMETRY 1
          runHook postInstall
        '';
        # Bun standalone executables carry a payload after the ELF sections.
        dontStrip = true;
      };
      cacheFor = pkgs:
        let
          downloads = pkgs.lib.mapAttrsToList (path: hash:
            let source = pkgs.fetchurl { url = "https://hub.bend-lang.com/${path}"; inherit hash; };
            in ''install -Dm644 ${source} "$out/${path}"'') locked.files;
          names = pkgs.lib.mapAttrsToList (name: hash:
            ''printf '%s\n' '${hash}' > "$out/names/${name}"'') locked.names;
        in pkgs.runCommand "ai-renamer-bend-dependencies" { } ''
          mkdir -p "$out/names"
          ${pkgs.lib.concatStringsSep "\n" (downloads ++ names)}
        '';
    in {
      packages = eachPlatform (pkgs: platform: {
        default = pkgs.llvmPackages.stdenv.mkDerivation {
          pname = "ai-renamer";
          version = "2.1.0";
          src = pkgs.lib.cleanSourceWith {
            src = pkgs.lib.cleanSource ./.;
            filter = path: _: baseNameOf path != ".build" && baseNameOf path != "result";
          };
          nativeBuildInputs = [ (bendFor pkgs platform) pkgs.gnumake ];
          buildInputs = [ pkgs.curl pkgs.openssl ];
          nativeCheckInputs = [ pkgs.python3 pkgs.ffmpeg pkgs.poppler-utils ];
          preBuild = ''
            export HOME="$TMPDIR/bend-home"
            mkdir -p "$HOME/.bend"
            ln -s ${cacheFor pkgs} "$HOME/.bend/lib"
          '';
          buildPhase = ''
            runHook preBuild
            make all
            runHook postBuild
          '';
          doCheck = true;
          checkPhase = ''
            runHook preCheck
            make test
            runHook postCheck
          '';
          installPhase = ''
            runHook preInstall
            make install PREFIX="$out"
            runHook postInstall
          '';
          meta.mainProgram = "ai-renamer";
        };
      });
      devShells = eachPlatform (pkgs: platform: {
        default = pkgs.mkShell.override { stdenv = pkgs.llvmPackages.stdenv; } {
          packages = [ (bendFor pkgs platform) pkgs.gnumake pkgs.curl pkgs.openssl pkgs.python3 pkgs.ffmpeg pkgs.poppler-utils ];
        };
      });
      apps = builtins.mapAttrs (system: _: {
        default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/ai-renamer";
        };
      }) platforms;
    };
}
