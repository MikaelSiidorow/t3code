{
  lib,
  stdenv,
  bun,
  nodejs_24,
  electron_40,
  jq,
  python3,
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
      python3
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
    export PYTHON="${lib.getExe python3}"
    export npm_config_python="$PYTHON"

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

    repo_root="$PWD"
    stage_root="$TMPDIR/t3code-stage"
    app_root="$stage_root/app"

    mkdir -p "$app_root/apps/desktop" "$app_root/apps/server"

    cp -a apps/desktop/dist-electron "$app_root/apps/desktop/"
    cp -a apps/desktop/resources "$app_root/apps/desktop/"
    cp -a apps/desktop/resources "$app_root/apps/desktop/prod-resources"
    cp -a apps/server/dist "$app_root/apps/server/"
    cp -a bun.lock "$app_root/bun.lock"

    cp -a node_modules "$app_root/node_modules"
    cp -a apps/desktop/node_modules "$app_root/apps/desktop/"
    cp -a apps/server/node_modules "$app_root/apps/server/"
    chmod -R u+w "$app_root/node_modules" "$app_root/apps/desktop/node_modules" "$app_root/apps/server/node_modules"

    export T3CODE_VERSION="${version}"
    export T3CODE_COMMIT_HASH="${commitHash}"

    node --input-type=module > "$app_root/package.json" <<'EOF'
    import rootPackageJson from "./package.json" with { type: "json" };
    import desktopPackageJson from "./apps/desktop/package.json" with { type: "json" };
    import serverPackageJson from "./apps/server/package.json" with { type: "json" };
    import { resolveCatalogDependencies } from "./scripts/lib/resolve-catalog.ts";

    const desktopRuntimeDependencies = Object.fromEntries(
      Object.entries(
        resolveCatalogDependencies(
          desktopPackageJson.dependencies,
          rootPackageJson.workspaces.catalog,
          "apps/desktop",
        ),
      ).filter(([name]) => name !== "electron"),
    );

    const stagePackageJson = {
      name: "t3code",
      version: process.env.T3CODE_VERSION,
      buildVersion: process.env.T3CODE_VERSION,
      t3codeCommitHash: process.env.T3CODE_COMMIT_HASH,
      private: true,
      description: "T3 Code desktop build",
      author: "T3 Tools",
      main: "apps/desktop/dist-electron/main.js",
      productName: desktopPackageJson.productName ?? "T3 Code (Alpha)",
      build: {
        appId: "com.t3tools.t3code",
        productName: desktopPackageJson.productName ?? "T3 Code (Alpha)",
        directories: {
          buildResources: "apps/desktop/resources",
          output: "dist",
        },
        mac: {
          target: ["dir"],
          icon: "icon.icns",
          category: "public.app-category.developer-tools",
        },
        linux: {
          target: ["dir"],
          executableName: "t3code",
          icon: "icon.png",
          category: "Development",
          desktop: {
            entry: {
              StartupWMClass: "t3code",
            },
          },
        },
      },
      dependencies: {
        ...resolveCatalogDependencies(
          serverPackageJson.dependencies,
          rootPackageJson.workspaces.catalog,
          "apps/server",
        ),
        ...desktopRuntimeDependencies,
      },
      devDependencies: {
        electron: desktopPackageJson.dependencies.electron,
      },
      overrides: resolveCatalogDependencies(
        rootPackageJson.overrides,
        rootPackageJson.workspaces.catalog,
        "root overrides",
      ),
    };

    process.stdout.write(JSON.stringify(stagePackageJson, null, 2) + "\n");
    EOF

    export T3CODE_STAGE_APP_ROOT="$app_root"

    node --input-type=module <<'EOF'
    import FS from "node:fs";
    import Path from "node:path";

    const appRoot = process.env.T3CODE_STAGE_APP_ROOT;
    if (!appRoot) {
      throw new Error("T3CODE_STAGE_APP_ROOT is required");
    }

    const stagePackageJson = JSON.parse(FS.readFileSync(Path.join(appRoot, "package.json"), "utf8"));
    const rootNodeModules = Path.join(appRoot, "node_modules");
    const sourceNodeModulesRoots = [
      Path.join(appRoot, "apps/server/node_modules"),
      Path.join(appRoot, "apps/desktop/node_modules"),
      rootNodeModules,
    ];

    for (const dependencyName of Object.keys(stagePackageJson.dependencies ?? {})) {
      const sourcePath = sourceNodeModulesRoots
        .map((nodeModulesRoot) => Path.join(nodeModulesRoot, dependencyName))
        .find((candidate) => FS.existsSync(candidate));

      if (!sourcePath) {
        throw new Error("Unable to locate staged dependency '" + dependencyName + "'");
      }

      const targetPath = FS.realpathSync(sourcePath);
      const destinationPath = Path.join(rootNodeModules, dependencyName);
      FS.rmSync(destinationPath, { force: true, recursive: true });
      FS.mkdirSync(Path.dirname(destinationPath), { recursive: true });
      FS.symlinkSync(
        Path.relative(Path.dirname(destinationPath), targetPath),
        destinationPath,
        "dir",
      );
    }
    EOF

    pushd "$app_root"

    export npm_config_nodedir=${electron.headers}
    export npm_config_runtime=electron
    export npm_config_target=${electron.version}
    export npm_config_devdir="$TMPDIR/node-gyp"
    node_gyp_js="$(find "$repo_root/node_modules/.bun" -path '*/node-gyp/bin/node-gyp.js' | head -n 1)"
    test -n "$node_gyp_js"

    pushd apps/server/node_modules/node-pty
    node "$node_gyp_js" rebuild
    popd

    find apps/server/node_modules/node-pty/build -name '*.node' -print -quit | grep -q .

    ${lib.optionalString stdenv.hostPlatform.isDarwin ''
      cp -R ${electron.dist}/Electron.app .
      chmod -R u+w Electron.app
      export CSC_IDENTITY_AUTO_DISCOVERY=false
    ''}
    ${lib.optionalString stdenv.hostPlatform.isLinux ''
      cp -R ${electron.dist} electron-dist
      chmod -R u+w electron-dist
    ''}

    node "$repo_root/node_modules/electron-builder/out/cli/cli.js" \
      ${if stdenv.hostPlatform.isDarwin then "--mac" else "--linux"} \
      --dir \
      -c.electronDist=${if stdenv.hostPlatform.isDarwin then "." else "electron-dist"} \
      -c.electronVersion=${electron.version} \
      -c.npmRebuild=false \
      ${lib.optionalString stdenv.hostPlatform.isDarwin "-c.mac.identity=null"}

    popd

    runHook postBuild
  '';

  checkPhase = ''
    runHook preCheck

    if [ ! -d "$TMPDIR/t3code-stage/app/dist" ]; then
      echo "electron-builder did not produce a dist directory"
      exit 1
    fi

    runHook postCheck
  '';

  installPhase =
    ''
      runHook preInstall
    ''
    + lib.optionalString stdenv.hostPlatform.isLinux ''
      shopt -s nullglob
      unpacked_dirs=("$TMPDIR"/t3code-stage/app/dist/*-unpacked)
      if [ "''${#unpacked_dirs[@]}" -ne 1 ]; then
        echo "expected exactly one linux unpacked output"
        exit 1
      fi

      unpacked_dir="''${unpacked_dirs[0]}"

      mkdir -p "$out/bin" "$out/share/t3code"

      cp -a "$unpacked_dir/locales" "$out/share/t3code/"
      cp -a "$unpacked_dir/resources" "$out/share/t3code/"
      if [ -f "$unpacked_dir/resources.pak" ]; then
        cp -a "$unpacked_dir/resources.pak" "$out/share/t3code/"
      fi

      install -Dm644 apps/desktop/resources/icon.png \
        "$out/share/icons/hicolor/512x512/apps/t3code.png"

      makeWrapper '${lib.getExe electron}' "$out/bin/t3code" \
        --add-flags "$out/share/t3code/resources/app.asar" \
        --set T3CODE_DISABLE_AUTO_UPDATE 1 \
        --set T3CODE_COMMIT_HASH "${commitHash}" \
        --set-default ELECTRON_FORCE_IS_PACKAGED 1
    ''
    + lib.optionalString stdenv.hostPlatform.isDarwin ''
      shopt -s nullglob
      app_bundles=("$TMPDIR"/t3code-stage/app/dist/mac*/*.app)
      if [ "''${#app_bundles[@]}" -ne 1 ]; then
        echo "expected exactly one macOS app bundle"
        exit 1
      fi

      mkdir -p "$out/Applications" "$out/bin"
      mv "''${app_bundles[0]}" "$out/Applications/"

      installed_bundles=("$out"/Applications/*.app)
      if [ "''${#installed_bundles[@]}" -ne 1 ]; then
        echo "expected exactly one installed macOS app bundle"
        exit 1
      fi

      app_bundle="''${installed_bundles[0]}"
      app_binary="$(find "$app_bundle/Contents/MacOS" -maxdepth 1 -type f | head -n 1)"
      test -n "$app_binary"

      makeBinaryWrapper "$app_binary" "$out/bin/t3code" \
        --set T3CODE_DISABLE_AUTO_UPDATE 1 \
        --set T3CODE_COMMIT_HASH "${commitHash}"
    ''
    + ''
      runHook postInstall
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
