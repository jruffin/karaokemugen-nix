let
  pname = "karaoke-mugen";
  version = "8.0.10";

  pkgs = import <nixpkgs> { };
  nixgl = import ./nixGL { };
  stdenv = pkgs.stdenv;
  lib = pkgs.lib;
  /*
    karaoke = pkgs.mkYarnPackage {
    name = "${pname}-${version}";
    src = pkgs.fetchFromGitLab {
      owner = "karaokemugen";
      repo = "code/karaokemugen-app";
      rev = version;
      hash = "sha256-orKDCHhgBZwXkGxexMI3tc7rurOjRJZN+WDmbdHkcz8=";
      leaveDotGit = true;
    };

    extraBuildInputs = with pkgs; [
      git
    ];

    postPatch = ''
    '';
    buildPhase = ''
      export HOME=$(mktemp -d)
      yarn --offline setup
      '';

    installPhase = ''mv -T deps/ulauncher-prefs/dist $out'';
    distPhase = "true";
    };
  */
  sources = pkgs.fetchFromGitLab {
    owner = "karaokemugen";
    repo = "code/karaokemugen-app";
    rev = version;
    fetchSubmodules = true;
    hash = "sha256-KDRaGgvVHqyUVvOT9WlLd1ZAt1kJ9GWsD5ZedRrifZs=";
  };

  extraNodePackages = stdenv.mkDerivation rec {
    name = "${pname}-extra-nodePackages";
    src = ./.;

    unpackPhase = ''
      	  echo '[ "electron-builder" ]' > package.json
      	'';

    buildInputs = with pkgs; [
      cacert
      nodePackages.node2nix
    ];

    buildPhase = ''
      	  runHook preBuild

      	  node2nix

      	  runHook postBuild
      	'';

    installPhase = ''
      	  runHook preInstall

      	  mkdir $out
      	  cp -rv ./* $out

      	  runHook postInstall
      	'';
  };

  p = pkgs.callPackage "${extraNodePackages}/default.nix" { };

  # replaces esbuild's download script with a binary from nixpkgs
  patchEsbuild = with pkgs; path: version: ''
    mkdir -p ${path}/node_modules/esbuild/bin
    jq "del(.scripts.postinstall)" ${path}/node_modules/esbuild/package.json | sponge ${path}/node_modules/esbuild/package.json
    sed -i 's/${version}/${esbuild.version}/g' ${path}/node_modules/esbuild/lib/main.js
    ln -s -f ${esbuild}/bin/esbuild ${path}/node_modules/esbuild/bin/esbuild
  '';

  kmRootYarn = stdenv.mkDerivation rec {
    inherit pname version;
    name = "${pname}-root-yarn";

		src = sources;

		yarnOfflineCache = pkgs.fetchYarnDeps {
			yarnLock = src + "/yarn.lock";
			hash = "sha256-WrR8hnnJ2KCUrYBDjWzE4/y9xlz8+NaF/rhY+I5jddo=";
		};

    ELECTRON_OVERRIDE_DIST_PATH="${pkgs.electron_31}/bin/";

    nativeBuildInputs = with pkgs; [
			#yarnConfigHook
			yarnBuildHook
			#yarnInstallHook
      yarn
      fixup-yarn-lock
      nodejs
      node-gyp
      husky
      rsync
      python3
      esbuild
      jq
      moreutils # for sponge
    ];

    buildInputs = with pkgs; [
      electron_31
    ];

    configurePhase = ''
      runHook preConfigure

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

      yarn install \
          --frozen-lockfile \
          --force \
          --production=false \
          --no-progress \
          --non-interactive \
          --offline

      # Make esbuild be able to find our own Electron
      # path.txt unfortunately does not suffice because it uses relative paths

      # TODO: Check if this is really needed
      patchShebangs node_modules

      echo "finished yarnConfigHook"

      runHook postConfigure
    '';

		# kmfrontend is a separate yarn project that will be dealt with in another derivation
		patchPhase = ''
			runHook prePatch
			rm -rf kmfrontend
			runHook postPatch
		'';

    # We have to run our configuration ourselves because yarnConfigHook skips package rebuilding,
    # which is needed e.g. by Electron
    # configurePhase = ''
    #   runHook preConfigure

    #   mkdir -p /tmp/home
    #   export HOME=/tmp/home

    #   yarn config --offline set yarn-offline-mirror "$yarnOfflineCache"

    #   fixup-yarn-lock yarn.lock

    #   yarn install --frozen-lockfile --force --production=false --non-interactive --offline --no-progress

    #   patchShebands node_modules

    #   runHook postConfigure
    # '';

		#yarnBuildScript = "typecheck";

    installPhase = ''
			mkdir -p $out/app
			rsync -var . $out/app
		'';
  };

  kmFrontendYarn = stdenv.mkDerivation rec {
    inherit pname version;
    name = "${pname}-frontend-yarn";

		src = sources;
		sourceRoot = "./source/kmfrontend";

		yarnOfflineCache = pkgs.fetchYarnDeps {
			inherit src;
			sourceRoot = "./source/kmfrontend";
			hash = "sha256-P8m8Z605FWjPN0kxL8I7WWFHiAGinFc8Cxb0EOJD5nc=";
		};

    nativeBuildInputs = with pkgs; [
			#yarnConfigHook
			yarnBuildHook
			#yarnInstallHook
      nodejs
      rsync
      dos2unix
      yarn
      fixup-yarn-lock
    ];

    patchPhase = ''
      runHook prePatch

      dos2unix vite.config.ts
      patch --verbose -u -p2 < ${./kmfrontend-rollup-externals.patch}
      unix2dos vite.config.ts

      runHook postPatch
    '';

    configurePhase = ''
      runHook preConfigure

      #export ELECTRON_SKIP_BINARY_DOWNLOAD=1

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
      #mkdir -p $HOME/.node-gyp/${pkgs.nodejs.version}
      #echo 9 > $HOME/.node-gyp/${pkgs.nodejs.version}/installVersion
      #ln -sfv ${pkgs.nodejs}/include $HOME/.node-gyp/${pkgs.nodejs.version}
      #export npm_config_nodedir=${pkgs.nodejs}

      # use updated node-gyp. fixes the following error on Darwin:
      # PermissionError: [Errno 1] Operation not permitted: '/usr/sbin/pkgutil'
      #export npm_config_node_gyp=${pkgs.node-gyp}/lib/node_modules/node-gyp/bin/node-gyp.js

      fixup-yarn-lock yarn.lock

      yarn install \
          --frozen-lockfile \
          --force \
          --production=false \
          --no-progress \
          --non-interactive \
          --offline

      # Make esbuild be able to find our own Electron
      #echo "${pkgs.electron_31}/bin/electron" > ./node_modules/electron/path.txt

      # TODO: Check if this is really needed
      patchShebangs node_modules

      echo "finished yarnConfigHook"

      runHook postConfigure
    '';

    installPhase = ''
			mkdir -p $out
			rsync -var . $out
		'';
  };

  postgresWithModdedConfig = stdenv.mkDerivation {
    name = pkgs.postgresql.name + "-mk-patched-config";
    version = pkgs.postgresql.version;

    src = pkgs.postgresql;

    nativeBuildInputs = with pkgs; [
      rsync
    ];

    buildInputs = with pkgs; [
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

      			rsync -ar . $out

      			runHook postInstall
      		'';
  };

  glWrappedMpv = pkgs.writeShellScriptBin "mpv" ''
    	${nixgl.nixGLMesa}/bin/nixGLMesa ${pkgs.mpv-unwrapped}/bin/mpv "$@"
  '';

in
stdenv.mkDerivation {
  inherit pname version;

  src = ./.;

  nativeBuildInputs = with pkgs; [
    rsync
    kmRootYarn 
		kmFrontendYarn
  ];

  buildInputs = with pkgs; [
    cacert
    # for Mugen's Postgres use which forces en_US.UTF-8
    glibcLocales
    yarn
    # Runtime dependencies
    postgresWithModdedConfig
    ffmpeg
    mpv-unwrapped
    nixgl.nixGLMesa
    glWrappedMpv
    patch
  ];

  phases = [ "installPhase" ];


  installPhase = ''
		runHook preInstall

		rsync -ar --progress ${kmRootYarn}/ $out

		chmod u+w $out/app

    # Reunite the root and frontend
    rsync -ar --progress ${kmFrontendYarn}/ $out/app/kmfrontend

		rm $out/app/portable
		touch $out/app/disableAppUpdate

		mkdir -p $out/app/app/bin
		ln -s ${postgresWithModdedConfig} $out/app/app/bin/postgres
		ln -s ${pkgs.ffmpeg}/bin/ffmpeg $out/app/app/bin/ffmpeg
		ln -s ${glWrappedMpv}/bin/mpv $out/app/app/bin/mpv
		ln -s ${pkgs.patch}/bin/patch $out/app/app/bin/patch

		chmod u-w $out/app

		runHook postInstall
	'';

  meta = with lib; {
    description = "Karaoke Mugen!";
    homepage = "https://mugen.karaokes.moe/";
    #license = licenses.mit;
    platforms = platforms.linux;
    #maintainers = with maintainers; [ hedning ];
  };
}
