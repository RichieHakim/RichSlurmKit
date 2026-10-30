#!/usr/bin/env python3
"""Packs claude-paste into a .vsix, the file `code --install-extension` takes.

Usage: pack.py OUT.vsix

A .vsix is a zip of the extension under extension/ plus two small manifests.
Writing it here avoids needing node's vsce tool to install the extension.
"""

import json
import sys
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
FILES = ["package.json", "extension.js", "files.js", "clipboard.html"]

CONTENT_TYPES = """<?xml version="1.0" encoding="utf-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
<Default Extension=".json" ContentType="application/json"/>
<Default Extension=".js" ContentType="application/javascript"/>
<Default Extension=".html" ContentType="text/html"/>
<Default Extension=".vsixmanifest" ContentType="text/xml"/>
</Types>
"""

MANIFEST = """<?xml version="1.0" encoding="utf-8"?>
<PackageManifest Version="2.0.0" xmlns="http://schemas.microsoft.com/developer/vsx-schema/2011" xmlns:d="http://schemas.microsoft.com/developer/vsx-schema-design/2011">
  <Metadata>
    <Identity Language="en-US" Id="{name}" Version="{version}" Publisher="{publisher}"/>
    <DisplayName>{display}</DisplayName>
    <Description xml:space="preserve">{description}</Description>
    <Categories>Other</Categories>
    <Properties>
      <Property Id="Microsoft.VisualStudio.Code.Engine" Value="{engine}"/>
      <Property Id="Microsoft.VisualStudio.Code.ExtensionKind" Value="workspace"/>
    </Properties>
  </Metadata>
  <Installation>
    <InstallationTarget Id="Microsoft.VisualStudio.Code"/>
  </Installation>
  <Dependencies/>
  <Assets>
    <Asset Type="Microsoft.VisualStudio.Code.Manifest" Path="extension/package.json" Addressable="true"/>
  </Assets>
</PackageManifest>
"""


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit(__doc__.strip().splitlines()[2])
    pkg = json.loads((HERE / "package.json").read_text())
    esc = lambda s: s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    manifest = MANIFEST.format(
        name=pkg["name"],
        version=pkg["version"],
        publisher=pkg["publisher"],
        display=esc(pkg["displayName"]),
        description=esc(pkg["description"]),
        engine=pkg["engines"]["vscode"],
    )
    with zipfile.ZipFile(sys.argv[1], "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("[Content_Types].xml", CONTENT_TYPES)
        z.writestr("extension.vsixmanifest", manifest)
        for name in FILES:
            z.write(HERE / name, f"extension/{name}")


if __name__ == "__main__":
    main()
