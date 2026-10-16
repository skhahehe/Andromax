# Andromax

**Native macOS file transfer for Android phones — over a USB cable, with no phone app to install.**

Andromax is a free, open-source Mac app for moving files between your Mac and any Android phone. Plug the phone in, pick **File Transfer** on the phone, and browse it like a Finder window: drag files in, copy them out, make folders, rename and delete.

It speaks both ways Android shares files over USB:

| Connection | What you do on the phone | Why use it |
|---|---|---|
| **MTP** | Choose **File Transfer** in the USB notification | Works on every Android phone, no settings to change |
| **ADB** | Turn on **USB debugging** and tap **Allow** | Faster, works with the screen locked, can reach the whole file system |

When both are available Andromax picks ADB and lets you switch with one click. A phone that offers both shows up once, not twice.

Andromax is and will always be **free and open source**.

## Features

- Native SwiftUI app, universal binary for **Intel and Apple Silicon** Macs (macOS 13 Ventura or later)
- Detects phones the moment they are plugged in and opens their main storage
- Drag files and folders from Finder into the window to copy them to the phone
- Copy to Downloads (double-click or the toolbar), Copy to…, or Move to Mac (copy, then delete from the phone)
- Folders upload and download with everything inside them
- Live progress with speed, a queue for several transfers, and cancel
- Asks before replacing files that already exist on the phone; never overwrites anything on your Mac
- New folder, rename, delete, search, sort, show/hide hidden files
- Opens folders with thousands of photos (DCIM/Camera) in a couple of seconds over MTP
- Sets itself up: on first run, if the Mac has no `adb`, Andromax downloads Google's official Android platform-tools (about 16 MB), checks they are signed by Google, and uses them. An `adb` you already have (Android Studio, Homebrew) is always preferred

## Tested phones

- **Google Pixel** (Pixel 6) — MTP and ADB
- **vivo** phones

Andromax should work with any Android phone that supports MTP or ADB. If you try another brand, please [open an issue](../../issues) saying whether it worked — that is one of the most useful contributions there is.

## Install

1. Download the latest `Andromax-x.y.z.dmg` from [Releases](../../releases) and open it.
2. **Right-click `Install Andromax.command` → Open**, then confirm. Terminal opens and asks for your Mac password (it won't show as you type).
   The script copies Andromax to `/Applications`, removes the download quarantine flag and opens the app.

**Why the script and the password?** Andromax is not signed with a paid Apple Developer ID yet, so macOS would otherwise say the app "is damaged" or "can't be opened". The script uses `sudo` only to install into `/Applications` and run `xattr -dr com.apple.quarantine` on the app. It is a few lines long — read it before running it.

Prefer doing it by hand? Drag `Andromax.app` onto `Applications`, then run:

```bash
xattr -dr com.apple.quarantine /Applications/Andromax.app
```

## How to use

### Over MTP (any phone, no setup)

1. Connect the phone with a USB cable that carries data (some cheap cables only charge) and **unlock it**.
2. Pull down the notification shade, tap **"Charging this device via USB"** and choose **File Transfer** (sometimes called "Transfer files" or "MTP").
3. Open Andromax. The phone appears in the sidebar with an **MTP** badge and its storage opens. The first connection can take a few seconds.

On its very first run Andromax also sets up ADB in the background (sidebar: "Setting up ADB (first run)…"). This needs internet once; MTP works without it.

### Over ADB (faster)

1. On the phone, open **Settings → About phone** and tap **Build number** seven times to enable Developer options.
2. In **Settings → System → Developer options**, turn on **USB debugging**.
3. Connect the cable and tap **Allow** on the "Allow USB debugging?" prompt (tick "Always allow from this computer").
4. The phone shows an **ADB** badge. If it also has MTP, use the **ADB | MTP** switch in the toolbar.

### Moving files

| To… | Do this |
|---|---|
| Copy to the phone | Drag files/folders from Finder into the window, or click **Copy to Phone** |
| Copy to the Mac | Select items and click **Copy to Mac** (goes to Downloads), double-click a file, or right-click → **Copy to…** |
| Move to the Mac | Right-click → **Move to Mac…** — originals are deleted from the phone only after they are copied |
| Open a folder | Double-click it; use the path bar or ⌘↑ to go back up |
| New folder / rename / delete | Toolbar, right-click menu, ⇧⌘N, or the Delete key |

## Troubleshooting

**The phone doesn't appear.** Make sure it is unlocked and set to **File Transfer**, not "Charging only". Try another cable or port.

**It appears but keeps loading, or says another app is using it.** macOS's own camera service grabs Android phones the moment they connect. Andromax pushes it out of the way automatically, but quit **Android File Transfer**, **Image Capture**, **Photos**, **Preview** and **Google Drive / Dropbox** if they are open, then unplug and replug the phone.

**ADB says "Tap Allow on the phone".** Unlock the phone and accept the USB debugging prompt. No prompt? Unplug and replug, or revoke USB debugging authorizations in Developer options and try again.

**Some file names are rejected.** Android does not allow `" * : < > ? \ |` in names on its shared storage.

**"Couldn't set up ADB".** The first-run download of Google's platform-tools failed (usually no internet). MTP still works; restart Andromax to try again, or install adb yourself with `brew install android-platform-tools`.

**A big folder takes a moment.** The bottom bar shows "Opening …" while it loads; folders with thousands of photos take a few seconds.

**Cancel waits a moment.** Large files stop between 8 MB pieces; small files finish first. This is deliberate: aborting mid-transfer makes some phones drop off USB.

## Build from source

Requirements: macOS 13+, Xcode 16+.

```bash
git clone https://github.com/<you>/andromax.git
cd andromax
open Andromax/Andromax.xcodeproj    # run from Xcode, or:
scripts/package.sh                  # universal Andromax.app + DMG in build/
```

`scripts/package.sh` is exactly what CI runs.

### Project layout

```
Andromax/Andromax/
  AndromaxApp.swift, ContentView.swift, BrowserView.swift   UI
  Browser.swift        navigation, file operations, transfer queue
  DeviceStore.swift    USB hotplug, ADB polling, merging MTP + ADB into one phone
  ADB.swift, ADBBackend.swift    adb process runner and file backend
  MTPBackend.swift     libmtp file backend (serial queue, chunked transfers)
  Frameworks/          universal libmtp + libusb dylibs
installer/             Install Andromax.command (put in the DMG)
scripts/package.sh     build + DMG
third_party/libmtp/    our patch to libmtp
```

### The bundled libraries

`libusb` 1.0 and `libmtp` 1.1.23 are built from source as universal dylibs (`-arch x86_64 -arch arm64 -mmacosx-version-min=11.0`). libmtp carries a small patch, [`third_party/libmtp/andromax.patch`](third_party/libmtp/andromax.patch), against upstream commit `eb12290b`:

- `LIBMTP_Get_Children_Fast()` — lists a folder with one bulk request per property instead of one request per file (minutes → seconds for big folders)
- releases the USB interface when opening a device fails, so a retry can succeed
- on macOS, stops retrying on a handle that a USB reset has already invalidated, and uses a shorter first-session timeout

To rebuild them, apply the patch to a libmtp checkout and configure both projects with the flags above (libmtp also needs `--disable-mtpz` and `--with-libiconv-prefix=$(xcrun --show-sdk-path)/usr am_cv_func_iconv_works=yes`), then fix the install names to `@rpath/…` with `install_name_tool` and copy the dylibs into both `Frameworks` folders.

## Releases (CI/CD)

[`.github/workflows/build.yml`](.github/workflows/build.yml) builds the universal app and DMG on every push to `main` and every pull request, and uploads the DMG as a workflow artifact.

To publish a release, push a version tag:

```bash
git tag v1.0.0
git push origin v1.0.0
```

The workflow then creates a GitHub Release named after the tag with `Andromax-1.0.0.dmg` (app + installer script) attached.

## Contributing

Contributions are welcome — bug reports, phone test reports, code and docs.

1. Fork the repository and create a branch: `git checkout -b fix/my-change`
2. Make your change and check it builds with `scripts/package.sh`
3. Push the branch to your fork and open a pull request describing what you changed and which phone(s) you tested with

Please keep pull requests focused on one change. For anything big, open an issue first so we can agree on the approach.

## License

Andromax is released under the [GNU General Public License v3.0](LICENSE). It is free to use, change and share, and the GPL keeps it that way: any version someone distributes must stay open source too.

It bundles [libmtp](https://github.com/libmtp/libmtp) and [libusb](https://github.com/libusb/libusb) (both LGPL-2.1, dynamically linked; our libmtp changes are published in `third_party/`). `adb` is not redistributed: it is downloaded on first run straight from Google's [Android SDK Platform-Tools](https://developer.android.com/tools/releases/platform-tools) into `~/Library/Application Support/Andromax/platform-tools`, under Google's terms.
