let
  pname = "karaoke-mugen";
  version = "8.0.10";

  pkgs = import <nixpkgs> {};
  nixgl = import ./nixGL {};
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
  src = pkgs.fetchFromGitLab {
	owner = "karaokemugen";
	repo = "code/karaokemugen-app";
	rev = version;
	fetchSubmodules = true;
	hash = "sha256-KDRaGgvVHqyUVvOT9WlLd1ZAt1kJ9GWsD5ZedRrifZs=";
  };

  #kmfrontend = pkgs.mkYarnPackage {
#	name = "${pname}-kmfrontend";
#	inherit version;
#	src = "${repo}/kmfrontend";
#  };

#  karaoke = pkgs.mkYarnPackage {
#	inherit pname version;
#
#	src = repo;
#
#	patchPhase = ''
#	  mv portable notportable
#	  '';

#	yarnPostBuild = ''
#	  pwd
#	  ls -la
#	  yarn installkmfrontend --offline
#	  yarn buildkmfrontend --offline

#	workspaceDependencies = [
#	  kmfrontend
#	];

    #installPhase = ''mv -T deps/ulauncher-prefs/dist $out'';
    #distPhase = "true";
#  };

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

  p = pkgs.callPackage "${extraNodePackages}/default.nix" {};

  yarnBuild = stdenv.mkDerivation rec {
    # I really tried to be smart with mkYarnPackage and such,
    # But the team behind Karaoke Mugen do such strange things with
    # Yarn that it is very hard to replicate what they do in a very Nixian way.
    # So we do it like they tell us to do a manual install, more or less.
	inherit pname version src;
	name = "${pname}-yarnbuild";

	buildInputs = with pkgs; [
	  cacert
	  nodejs
	  yarn
	  rsync
	  python3
	  git
      #p.electron-builder
	];

	buildPhase = ''
	  HOME=$(mktemp -d)
	  #HOME=$out/home
	  npm config set prefix $HOME/.npm
	  yarn config set prefix $HOME/.yarn
	  export NODE_OPTIONS=--max-old_space_size=3072
	  yarn install
	  yarn build
	  yarn installkmfrontend
	  yarn buildkmfrontend
	'';

	installPhase = ''
	  mkdir -p $out/app
	  rsync -var . $out/app
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

	phases = ["unpackPhase" "patchPhase" "installPhase"];

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
	yarnBuild
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

  phases = ["installPhase"];


  installPhase = ''
	runHook preInstall

	rsync -ar --progress ${yarnBuild}/ $out

	chmod u+w $out/app

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
