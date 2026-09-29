# MKS DLC32 V2 on OpenBuilds CONTROL v1.0.390

This branch starts at upstream tag `v1.0.390` and contains a local machine configuration for an MKS DLC32 V2 running firmware `1.1.2022051001`.

- Network scan and Telnet connection use TCP port `8080`.
- `192.168.74.199 [grbl]` appears in Network Ports at startup and is selected by default. Press **Connect** to open the connection; startup does not connect automatically.
- The manual scan dialog defaults to `192.168.74.1-192.168.74.255`. The saved DLC32 entry remains listed if a scan finds no devices.
- USB/Serial connection code is unchanged.

The source changes are in `index.js` and `app/js/websocket.js`. The installed Windows application can be updated without building the Electron project:

```powershell
pwsh -NoProfile -File .\scripts\patch-installed-asar.ps1
```

Close OpenBuilds CONTROL before running the script. It requires PowerShell 7, Node.js 22.12 or newer, npm, and an installed CONTROL v1.0.390. It backs up the installed `app.asar`, extracts it, replaces only the two changed source files, repacks it with the original external firmware files preserved, verifies the result, then replaces the archive. It installs a pinned `@electron/asar` tool into a temporary work directory; project dependencies are not changed.

To restore the previous archive, close CONTROL and copy the `app.asar` from the backup directory printed by the script to `%LOCALAPPDATA%\Programs\OpenBuildsCONTROL\resources\app.asar`. In PowerShell 7:

```powershell
Copy-Item -LiteralPath 'PATH_FROM_SCRIPT\app.asar' -Destination (Join-Path $env:LOCALAPPDATA 'Programs\OpenBuildsCONTROL\resources\app.asar') -Force
```

This is a machine-specific branch and is not a general port-selection implementation. No installed binaries or user settings are committed. The upstream `LICENSE` file contains GPLv3 text, while its `package.json` declares `AGPL-3.0`; both upstream files are left unchanged.
