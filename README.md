# lenovo-bios-fwupd

_Install BIOS/UEFI firmware updates for modern Lenovo Legion laptops on Linux, without needing Windows!_

lenovo-bios-fwupd converts Lenovo Windows BIOS update `.exe` files (Insyde H2OFFT based) into fwupd-compatible `.cab` files that can be installed from Linux.

Many Lenovo laptops don't receive BIOS updates through [LVFS](https://fwupd.org/), so the only official update path is a Windows `.exe`. This script extracts the firmware from that `.exe`, reads your system's EFI System Resource Table (ESRT) to get the correct GUID, and packages everything into a `.cab` that `fwupdmgr` can install natively.

## Requirements

- `7z` (p7zip)
- `gcab`
- `fwupdmgr` (fwupd)
- `python3`

## Downloading the BIOS update

1. Go to [Lenovo PC Support](https://pcsupport.lenovo.com/).
2. Find your laptop model (e.g. search for "Legion Pro 7 16IAX10H").
3. Navigate to **Drivers & Software** and filter by the **BIOS/UEFI** component. For example, for the Legion Pro 7 16IAX10H, [this](https://pcsupport.lenovo.com/fr/fr/products/laptops-and-netbooks/legion-series/legion-pro-7-16iax10h/downloads/driver-list/component?name=BIOS%2FUEFI&id=5AC6A815-321D-440E-8833-B07A93E0428C) is the direct link.
4. Download the latest BIOS update `.exe` file.

## Usage

```bash
./lenovo-bios-fwupd.sh <bios_update.exe>
```

The script will:

1. Extract the `.exe` archive with `7z`.
2. Locate the firmware image inside, using `platform.ini` to decide which file it is.
3. Check that any other firmware blobs in the package are inside that image.
4. Read the BIOS version string from the firmware image.
5. Read your system's firmware GUID and current version from the ESRT.
6. Generate fwupd-compatible metainfo XML.
7. Package everything into a `.cab` file.

Then install the resulting `.cab`:

```bash
sudo fwupdmgr install <version>.cab --allow-reinstall --no-reboot-check
```

**You will need to add `OnlyTrusted=false` to `/etc/fwupd/fwupd.conf` since the resulting .cab file will not be signed.**

Reboot to apply the update. The UEFI firmware will apply the capsule during boot.

**Important:** Ensure AC power is connected and battery is above 30% before installing. Do **not** interrupt the reboot after installation.

## How the firmware image is located

`platform.ini` has an `[FDFile]` section naming the image to flash. Insyde's own documentation, embedded in that same file, states that when `FileName` is empty the utility loads the first `.fd` file it finds, which is the case on the Legion and IdeaPad packages. Others, such as the Yoga Pro 7 14ASP10, name the image explicitly, and it need not be a `.fd`:

```ini
[FDFile]
FileName=KLS7A.bin
;(wW)
;FileName          default : empty.
;                   String : Utility always load this file.
;                            If the FileName is empty, utility will search current directory
;                              and load the first found FD file.
```

The script honors the key when it is set and falls back to the first `.fd` when it is empty, so previously supported models are unaffected. Despite the differing extension, the two are the same kind of artifact.

Some packages ship other firmware blobs alongside the image; the Yoga Pro 7 14ASP10 includes `Ecb.bin`, ITE IT5508 embedded controller firmware. It is contained verbatim inside the main image and `platform.ini` leaves the separate-EC-image path disabled, so ignoring it is safe. More generally, since the `.cab` carries only the `FileName` image from above, the script checks whether each extra blob is already inside it:

```
  OK: Secondary firmware Ecb.bin is contained in KLS7A.bin at 0x1817b0
```

If one is not, you'll get a warning: it may be a component that only the Windows updater flashes (via a separate path, like the Intel firmware update tool `FWUpdLcl.exe`), in which case this update will leave it on its current version.

*Note*: all tested laptops so far either contain a single image, or ship exactly one redundant secondary image; the above was inferred from the Insyde documentation contained inside `platform.ini`.

## Tested laptops

| Model                     | Status          |
|---------------------------|-----------------|
| Legion Pro 7 16IAX10H     | Tested, working |
| IdeaPad Pro 5 16IAH10     | Tested, working |
| Yoga 9 2in-1 14ILL10      | Tested, working |
| Legion 5 15AHP10          | Tested, working |
| Yoga Pro 7 Gen 10 14ASP10 | Tested, working |

> [!NOTE]
> This script was used to successfully update the Yoga Pro 7 14ASP10 from version QFCN26WW to QFCN29WW, so it should be safe to skip intermediate images and just use the latest available one.

This script should work on other Lenovo laptops that use Insyde H2OFFT-based BIOS updates with a `.fd` or `.bin` firmware file inside the `.exe`. If you test it on another model, please open an issue or PR to update this table.

## License

GPLv2. See [LICENSE](LICENSE).
