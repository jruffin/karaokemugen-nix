let
  pname = "karaokemugen";
  version = "8.0.22";
  gitHash = "sha256-7ufTJtO03tDGN6oN2jVCKLkoFox0Cizrfa+EGP4lE+M=";
  kmYarnHash = "sha256-TEoVy9JB0UifE72ahEd2csgM57e/XZd1kl8eiV9QfIk=";
  kmFrontendYarnHash = "sha256-evl77qf62ZO0Kv4/sH4EVNoWkENxmNee2QQesrnPorU=";

  pkgs = import <nixpkgs> { };
  nixgl = import ./nixGL { };

  stdenv = pkgs.stdenv;
  lib = pkgs.lib;
  sources = pkgs.fetchFromGitLab {
    owner = "karaokemugen";
    repo = "code/karaokemugen-app";
    rev = version;
    fetchSubmodules = true;
    leaveDotGit = true;
    hash = gitHash;
  };

  # replaces esbuild's download script with a binary from nixpkgs
  #patchEsbuild = with pkgs; path: version: ''
  # mkdir -p ${path}/node_modules/esbuild/bin
  # jq "del(.scripts.postinstall)" ${path}/node_modules/esbuild/package.json | sponge ${path}/node_modules/esbuild/package.json
  # sed -i 's/${version}/${esbuild.version}/g' ${path}/node_modules/esbuild/lib/main.js
  # ln -s -f ${esbuild}/bin/esbuild ${path}/node_modules/esbuild/bin/esbuild
  #';

  karaokemugen-yarn = stdenv.mkDerivation rec {
    inherit version;
    name = pname + "-yarn";

    src = sources;

    yarnOfflineCache = pkgs.symlinkJoin {
      name = "offline";
      paths = [
        (pkgs.fetchYarnDeps {
          inherit src;
          hash = kmYarnHash;
        })
        (pkgs.fetchYarnDeps {
          inherit src;
          sourceRoot = "${src}/kmfrontend";
          hash = kmFrontendYarnHash;
        })
      ];
    };

    ELECTRON_OVERRIDE_DIST_PATH = "${pkgs.electron}/bin/";

    nativeBuildInputs = with pkgs; [
      yarn
      fixup-yarn-lock
      nodejs
      node-gyp
      husky
      python3
      esbuild
      jq
      moreutils # for sponge
    ];

    buildInputs = with pkgs; [
      electron
    ];

    yarnConfigureFlags = "--frozen-lockfile --force --production=false --no-progress --non-interactive";

    configurePhase = ''
      runHook preConfigure

      echo "starting yarn configure/install"

      export ELECTRON_SKIP_BINARY_DOWNLOAD=1

      # Use a constant HOME directory
      mkdir -p /tmp/home
      export HOME=/tmp/home
      if [[ -n "$yarnOfflineCache" ]]; then
          offlineCache="$yarnOfflineCache"
      fi
      if [[ -z "$offlineCache" ]]; then
          echo yarnConfigHook: No yarnOfflineCache or offlineCache were defined\! >&2
          exit 2
      fi
      yarn config --offline set yarn-offline-mirror "$offlineCache"

      # set nodedir to prevent node-gyp from downloading headers
      # taken from https://nixos.org/manual/nixpkgs/stable/#javascript-tool-specific
      mkdir -p $HOME/.node-gyp/${pkgs.nodejs.version}
      echo 9 > $HOME/.node-gyp/${pkgs.nodejs.version}/installVersion
      ln -sfv ${pkgs.nodejs}/include $HOME/.node-gyp/${pkgs.nodejs.version}
      export npm_config_nodedir=${pkgs.nodejs}

      # use updated node-gyp. fixes the following error on Darwin:
      # PermissionError: [Errno 1] Operation not permitted: '/usr/sbin/pkgutil'
      export npm_config_node_gyp=${pkgs.node-gyp}/lib/node_modules/node-gyp/bin/node-gyp.js

      fixup-yarn-lock yarn.lock
      fixup-yarn-lock kmfrontend/yarn.lock

      yarn --offline install $yarnConfigureFlags
      yarn --offline installkmfrontend $yarnConfigureFlags

      patchShebangs node_modules
      patchShebangs kmfrontend/node_modules

      echo "finished yarn configure/install"

      runHook postConfigure
    '';

    buildPhase = ''
      runHook preBuild

      echo "starting yarn build"

      # Required or we run out of memory during the build on e.g. Raspberry Pis
      export NODE_OPTIONS="--max_old_space_size=3072"

      yarn --offline build
      yarn --offline buildkmfrontend

      echo "finished yarn build"

      runHook postBuild
    '';

    yarnInstallFlags = "--frozen-lockfile --force --production=true --no-progress --non-interactive";

    installPhase = ''
      runHook preInstall

      echo "starting yarn installation"

      yarn --offline install $yarnInstallFlags
      yarn --offline installkmfrontend $yarnInstallFlags

      mkdir -p $out/app
      cp -ar . $out/app

      echo "finished yarn installation"

      runHook postInstall
    '';
  };

  postgresWithModdedConfig = stdenv.mkDerivation {
    name = pkgs.postgresql.name + "-mk-patched-config";
    version = pkgs.postgresql.version;

    src = pkgs.postgresql;

    propagatedBuildInputs = with pkgs; [
      postgresql
    ];

    phases = [ "unpackPhase" "patchPhase" "installPhase" ];

    # Unpacking phase: copy everything from the original package,
    # but as symlinks to save space
    unpackPhase = ''
      runHook preUnpack

      cp -rs $src/* .

      runHook postUnpack
    '';

    # Patch phase: override the files we want to change by replacing
    # their respective symlinks with actual files
    patchPhase = ''
      runHook prePatch

      pushd share/postgresql

      CONF=postgresql.conf.sample

      chmod +w .
      cp --remove-destination $(readlink "$CONF") "$CONF"
      chmod 777 "$CONF"
      chmod -w .
      echo "unix_socket_directories = '/tmp'" >> "$CONF"
      popd

      runHook postPatch
    '';

    installPhase = ''
      runHook preInstall

      cp -ar . $out

      runHook postInstall
    '';
  };

  glWrappedMpv = pkgs.writeShellApplication {
    name = "mpv";

    runtimeInputs = [ nixgl.auto.nixGLDefault pkgs.mpv-unwrapped ];

    text = ''
      nixGL mpv "$@"
    '';
  };

  karaokemugen-app = stdenv.mkDerivation rec {
    inherit pname version;

    src = karaokemugen-yarn;

    nativeBuildInputs = with pkgs; [
      makeWrapper
    ];

    propagatedBuildInputs = with pkgs; [
      cacert
      # for Mugen's Postgres use which forces en_US.UTF-8
      glibcLocales
      # Direct runtime dependencies
      electron
      postgresWithModdedConfig
      ffmpeg
      glWrappedMpv
      patch
      nixgl.auto.nixGLDefault
    ];

    phases = [ "installPhase" ];

    installPhase = ''
      runHook preInstall

      cp -ar $src $out

      chmod u+w $out/app

      rm $out/app/portable
      touch $out/app/disableAppUpdate

      mkdir -p $out/app/app/bin
      ln -s ${postgresWithModdedConfig} $out/app/app/bin/postgres
      ln -s ${pkgs.ffmpeg}/bin/ffmpeg $out/app/app/bin/ffmpeg
      ln -s ${glWrappedMpv}/bin/mpv $out/app/app/bin/mpv
      ln -s ${pkgs.patch}/bin/patch $out/app/app/bin/patch

      chmod u-w $out/app

      chmod u+w $out
      makeWrapper ${nixgl.auto.nixGLDefault}/bin/nixGL "$out/bin/karaokemugen" \
        --inherit-argv0 --chdir $out/app --add-flags "${pkgs.electron}/bin/electron ." \
        --prefix PATH : ${lib.makeBinPath propagatedBuildInputs} \
        --set LOCALE_ARCHIVE $LOCALE_ARCHIVE \
        --set PGHOST /tmp
      chmod u-w $out

      runHook postInstall
    '';
  };

  meta = with lib; {
    description = "Karaoke Mugen!";
    homepage = "https://mugen.karaokes.moe/";
    #license = licenses.mit;
    platforms = platforms.linux;
    #maintainers = with maintainers; [ hedning ];
  };
in
karaokemugen-app