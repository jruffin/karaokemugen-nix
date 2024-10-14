let
  pname = "karaokemugen";
  version = "8.0.22";
  gitHash = "sha256-LtIzVIxUrivufgbCUhlnRnqF3FF8T5KE/NXoHFjp1hE=";
  kmYarnHash = "sha256-TEoVy9JB0UifE72ahEd2csgM57e/XZd1kl8eiV9QfIk=";
  kmFrontendYarnHash = "sha256-evl77qf62ZO0Kv4/sH4EVNoWkENxmNee2QQesrnPorU=";

  pkgs = import <nixpkgs> { };
  nixgl = import ./nixGL { };
  /*nixgl = import (pkgs.fetchFromGitHub {
    owner = "jruffin";
    repo = "nixGL";
    rev = "main";
    hash = "sha256-SIRmGyZFEU5EbqlTAcqvuslyV0//1+2PQj+PsCMujDw=";
  }) { };*/

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

  postgresWithModdedConfig = pkgs.symlinkJoin {
    name = pkgs.postgresql.name + "-patched-config";
    version = pkgs.postgresql.version;
    buildInputs = [pkgs.postgresql] ++ pkgs.postgresql.buildInputs;
    paths = [
      # Whichever paths come first have priority,
      # so the derivation that patches the config file
      # has to come first to be in the final package
      (pkgs.concatTextFile {
        name = "patched-postgresql-conf-sample";
        files = [
          "${pkgs.postgresql}/share/postgresql/postgresql.conf.sample"
          (pkgs.writeText "set-unix-socket-directories-to-tmp" "unix_socket_directories = '/tmp'")
        ];
        destination = "/share/postgresql/postgresql.conf.sample";
      })
      pkgs.postgresql
    ];
  };

  glWrappedMpv = pkgs.writeShellApplication {
    name = "mpv";

    runtimeInputs = [ nixgl.auto.nixGLDefault pkgs.mpv-unwrapped ];

    text = ''
      nixGL mpv "$@"
    '';
  };

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
    ELECTRON_SKIP_BINARY_DOWNLOAD = "1";

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

      echo "starting electron-builder"

      source util/versionUtil.sh
      yarn --offline run electron-builder -l --dir --publish always \
        ${lib.optionalString stdenv.hostPlatform.isx86_64 "--x64"} \
        ${lib.optionalString stdenv.hostPlatform.isAarch64 "--arm64"} \
        -c.extraMetadata.version=$BUILDVERSION \
        -c.electronDist=${pkgs.electron.dist} \
        -c.electronVersion=${pkgs.electron.version}

      echo "finished electron-builder"

      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall

      echo "starting yarn installation"

      mkdir -p $out/app
      cp -ar packages/*-unpacked/{locales,resources,*.pak} $out/app

      echo "finished yarn installation"

      runHook postInstall
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

      chmod -R u+w $out/app

      mkdir -p $out/app/resources/app/bin
      ln -s ${postgresWithModdedConfig} $out/app/resources/app/bin/postgres
      ln -s ${pkgs.ffmpeg}/bin/ffmpeg $out/app/resources/app/bin/ffmpeg
      ln -s ${glWrappedMpv}/bin/mpv $out/app/resources/app/bin/mpv
      ln -s ${pkgs.patch}/bin/patch $out/app/resources/app/bin/patch

      chmod -R u-w $out/app

      chmod u+w $out
      makeWrapper ${nixgl.auto.nixGLDefault}/bin/nixGL "$out/bin/karaokemugen" \
        --inherit-argv0 --add-flags "${pkgs.electron}/bin/electron" --add-flags "$out/app/resources/app.asar" \
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