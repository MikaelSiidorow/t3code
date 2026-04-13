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
