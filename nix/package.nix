{
  lib,
  stdenv,
  bun,
  nodejs_24,
  electron_40,
  jq,
  makeWrapper,
  makeBinaryWrapper,
  makeDesktopItem,
  copyDesktopItems,
  writableTmpDirAsHomeHook,
  src,
  commitHash ? "dirty",
}:
let
  nodejs = nodejs_24;
  electron = electron_40;
  packageJson = builtins.fromJSON (builtins.readFile "${src}/apps/server/package.json");
  desktopPackageJson = builtins.fromJSON (builtins.readFile "${src}/apps/desktop/package.json");
  pname = "t3code";
  version = packageJson.version;
  workspaceNodeModules = stdenv.mkDerivation {
    pname = "${pname}-workspace-node-modules";
    inherit version src;

    nativeBuildInputs = [
      bun
      writableTmpDirAsHomeHook
    ];

    dontConfigure = true;
    dontFixup = true;

    buildPhase = ''
      runHook preBuild

      export HOME="$TMPDIR"
      export BUN_INSTALL_CACHE_DIR="$(mktemp -d)"
      export ELECTRON_SKIP_BINARY_DOWNLOAD=1

      bun install --frozen-lockfile --ignore-scripts --no-progress

      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall

      mkdir -p "$out"
      cp -a node_modules "$out/node_modules"

      for workspaceNodeModules in apps/*/node_modules packages/*/node_modules scripts/node_modules; do
        if [ -d "$workspaceNodeModules" ]; then
          mkdir -p "$out/$(dirname "$workspaceNodeModules")"
          cp -a "$workspaceNodeModules" "$out/$(dirname "$workspaceNodeModules")/"
        fi
      done

      runHook postInstall
    '';

    outputHashMode = "recursive";
    outputHash = "sha256-5CI0WZ2MojUnG9LMgEp6raqj7y8wZ3tl+kabar1KMa0=";
  };
in
stdenv.mkDerivation (finalAttrs: {
  inherit pname version src;

  nativeBuildInputs =
    [
      bun
      nodejs
      jq
      writableTmpDirAsHomeHook
    ]
    ++ lib.optionals stdenv.hostPlatform.isLinux [
      makeWrapper
      copyDesktopItems
    ]
    ++ lib.optionals stdenv.hostPlatform.isDarwin [
      makeBinaryWrapper
    ];

  env.ELECTRON_SKIP_BINARY_DOWNLOAD = "1";

  dontConfigure = true;

  buildPhase = ''
    runHook preBuild

    export HOME="$TMPDIR"
    export BUN_INSTALL_CACHE_DIR="$(mktemp -d)"

    cp -R ${workspaceNodeModules}/. .
    patchShebangs node_modules

    if [ "$(jq -r '.dependencies.electron' < apps/desktop/package.json | cut -d. -f1)" != "${lib.versions.major electron.version}" ]; then
      echo "electron major version mismatch between apps/desktop/package.json and nixpkgs electron_40"
      exit 1
    fi

    bun run build:desktop

    test -f apps/desktop/dist-electron/main.js
    test -f apps/server/dist/bin.mjs
    test -f apps/server/dist/client/index.html

    runHook postBuild
  '';

  desktopItems = lib.optional stdenv.hostPlatform.isLinux (makeDesktopItem {
    name = "t3code";
    desktopName = desktopPackageJson.productName;
    exec = "t3code %U";
    icon = "t3code";
    comment = "T3 Code desktop app";
    categories = [
      "Development"
      "IDE"
    ];
    startupWMClass = "t3code";
  });

  meta = {
    description = "T3 Code desktop app";
    homepage = "https://github.com/pingdotgg/t3code";
    license = lib.licenses.mit;
    mainProgram = "t3code";
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
      "x86_64-darwin"
      "aarch64-darwin"
    ];
  };
})
