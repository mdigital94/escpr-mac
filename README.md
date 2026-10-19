# escpr-mac

Native Apple Silicon build of the open source **Epson ESC/P-R** inkjet printer driver, for old Epson printers that no longer have a working macOS driver on M1 and later Macs.

One script downloads Epson's driver source, patches it for the macOS compiler, builds it natively for arm64, installs it and sets up the print queue. No Rosetta, no Intel binaries.

[Leggi in italiano](README.it.md)

## Why

Many older Epson inkjets still work perfectly, but Epson never shipped Apple Silicon drivers for them. The Mac sees the printer on USB and then cannot talk to it. Epson did publish an open source driver for Linux (ESC/P-R) that covers hundreds of these models: this project makes it build and run on macOS.

## Supported printers

The driver covers **620 Epson inkjet models**, including:

- Stylus, Stylus Photo and Stylus Office (SX, TX, NX, BX, DX series and more)
- Expression (XP series)
- WorkForce (WF and WP series)
- EcoTank (ET and L series)
- Artisan, PictureMate, ME Office, and the PX and EP series sold in Japan

To check your model:

```
bash install.sh --list sx218
bash install.sh --list "xp 6"
```

Not supported: Epson laser printers, newer Epson models that use the ESC/P-R2 driver, and other brands.

**Tested on:** Epson Stylus SX218 over USB with a MacBook Pro M5. Other models use the same driver code and are expected to work, but have not been tested. Reports are welcome in the issues.

## Requirements

- A Mac with Apple Silicon (M1 or later)
- Xcode Command Line Tools: the script offers to install them if missing
- An internet connection during installation
- An administrator password

## Install

Connect the printer with USB, switch it on, then:

```
git clone https://github.com/mdigital94/escpr-mac.git
cd escpr-mac
bash install.sh
```

The script finds the Epson printer on USB, picks the right model file, builds the driver, removes old queues for the same printer that could not print, creates a new queue and offers a test page.

### Options

| Command | What it does |
|---|---|
| `bash install.sh` | Detects a USB Epson printer and sets everything up |
| `bash install.sh --model "XP-600"` | Uses this model instead of auto detection |
| `bash install.sh --model "XP-600" --uri "socket://192.168.1.50"` | Sets up a network printer at that address |
| `bash install.sh --model "XP-600" --driver-only` | Installs the driver only; add the printer later in System Settings |
| `bash install.sh --list [filter]` | Lists supported models |
| `bash install.sh --uninstall` | Removes driver, model files and the queues it created |

With `--driver-only`, go to System Settings, Printers & Scanners, add the printer and choose the driver named `<model>, ESC/P-R (Apple Silicon)`.

## Uninstall

```
bash install.sh --uninstall
```

This removes `/Library/Printers/ESCPR`, `/Library/Printers/PPDs/Contents/Resources/ESCPR` and every print queue that uses this driver.

## How it works

The script downloads ESC/P-R 1.8.9 from a pinned commit and checks its SHA-256 checksum before building. It then applies four small source patches, needed because the code was written for Linux only:

1. **Missing function declarations.** Some functions are called without a prototype. Apple clang treats this as an error, and on arm64 it can corrupt return values. The script adds the correct prototypes.
2. **Duplicate global variable.** `jobFnc` is defined in both the filter and the library. Apple's linker rejects it, so the filter now refers to the library's copy.
3. **Unix only code.** The platform layer (memory, timing, locks) is compiled only when the `unix` macro is defined, which Apple clang does not do. The script adds `__APPLE__` to those conditions.
4. **Reading the PPD.** The filter asked the print server for its configuration file, which can fail inside the macOS filter sandbox. It now reads the path CUPS passes in the `PPD` environment variable.

It then builds static arm64 binaries, installs them in `/Library/Printers/ESCPR/filter` (owned by root, as CUPS requires) and rewrites the model's PPD so CUPS calls the filter by its absolute path. System folders protected by macOS are never touched.

## Troubleshooting

**The build stops with an error.** The script saves the full log to `~/Downloads/escpr_make.log`. Please attach it to an issue.

**The test page stays in the queue.** Check the print system log:

```
grep -i "escpr\|sandbox" /var/log/cups/error_log | tail -n 40
```

If you see sandbox denials, the macOS filter sandbox is blocking the driver. Please open an issue with those lines.

**My model is not found on USB.** Run `lpinfo -v` to see how macOS names the printer, then pass the model by hand with `--model`.

**Scanning.** This project covers printing only. For the scanner of an all in one, try Image Capture or Preview first, which often work with Apple's built in scanner support.

## Credits and license

- The driver is **Epson Inkjet Printer Driver (ESC/P-R) for Linux** by Seiko Epson Corporation, released under the GNU GPL version 2 or later.
- The source is downloaded from the [vmartins/epson-inkjet-printer-escpr](https://github.com/vmartins/epson-inkjet-printer-escpr) mirror, pinned to a single commit and verified by checksum.
- This project is released under the same license, **GPL-2.0-or-later**. See [LICENSE](LICENSE).

## Disclaimer

This is an unofficial project, not affiliated with or endorsed by Seiko Epson Corporation or Apple. Epson, Stylus, Expression, WorkForce and EcoTank are trademarks of Seiko Epson Corporation. Use it at your own risk.
