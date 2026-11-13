# Gamma Forge (display-gamma-forge)

[한국어](README.ko.md)

A display gamma/tone curve adjuster for macOS. Fine-tune by eye, no colorimeter needed, and output the result as an **ICC profile**.

Not an always-on app — it's a tool that generates a color profile. Quitting the app returns the screen to its original setting; select the new profile in System Settings › Displays › Color Profile to apply the result.

Supports macOS 12 (Monterey) or later, both x86_64 and arm64.

## Install

An x86_64/arm64 universal binary is published on [Releases](https://github.com/wooooooooook/display-gamma-forge/releases). [install.sh](install.sh) downloads the latest version and verifies its checksum.

```sh
curl -fsSL https://raw.githubusercontent.com/wooooooooook/display-gamma-forge/main/install.sh | sh
```

> The binary isn't signed or notarized. Run it only after `install.sh`'s checksum verification succeeds.

## Why

macOS's auto-generated factory profile (from EDID) varies slightly in gamma and white point between monitors, and macOS doesn't offer a way to fine-tune it. Gamma Forge takes the factory profile as a base and adjusts only gamma, white balance, and per-channel midtones to produce a new ICC profile. Use it when the monitor itself lacks color adjustment, or has too little of it.

Fix the monitor at max brightness, or whatever brightness you normally use, before adjusting with Gamma Forge.

## How it works

- Preview: overwrites the display gamma table (where vcgt loads) in real time via `CGSetDisplayTransferByTable`. macOS restores the original setting automatically when the app quits.
- Curve: for each channel c (R/G/B), computes a 256-point 16-bit table with:

  ```
  out(x) = gain_c * x ^ ( (native gamma / target gamma) * channel gamma_c )
  ```

  - Target gamma: lower values deepen midtones (higher contrast).
  - Gain: the channel's max output. Sets white's color cast (temperature/tint).
  - Channel gamma: leaves white/black fixed, shifts only mid/dark tones. A different concept from black-level offset.
- Save: keeps the base factory profile's primaries, white point, TRC, and chad untouched; removes the existing vcgt and adds a new vcgt (type 0 table, 3 channels × 256 × 16-bit) and a new name (desc), saved to `~/Library/ColorSync/Profiles/`. The factory profile itself is never modified.
- Base mismatch warning: a color-managed app's preview goes through *whatever profile is currently selected in System Settings*, so if that profile's primaries/white/TRC differ from the save base, the preview and the saved result can diverge. The app detects this and warns you.

## Build from source

Requires Xcode Command Line Tools.

```sh
xcode-select --install
swiftc -parse-as-library -O GammaForge.swift -o GammaForge
./GammaForge
```

## Usage

1. Pick the monitor to adjust at the top. "Base for saving" shows which profile (usually the factory one) the save will be based on.
2. Adjust the Target Gamma / Gain (R·G·B) / Channel Gamma (R·G·B) sliders, checking the result live against the screen and the test pattern below (steps and gradient).
3. Use "Show original" to compare against the unadjusted state, or "Reset" to revert.
4. Once satisfied, name it and press "Save Only" or "Save & Quit". The file is written to `~/Library/ColorSync/Profiles/<name>.icc`.
5. Select the new profile in System Settings › Displays › Color Profile.
6. If you overwrote the same name, select a different profile once and reselect it, so the system doesn't keep using a cached copy.

## Caveats

- Fix the monitor at max brightness, or whatever brightness you normally use, before adjusting. A monitor's white point shifts slightly with brightness (greener at max, redder at low), and a fixed vcgt can't compensate for that.
- Turn off Night Shift / True Tone while adjusting. Both alter screen color in real time and will distort the curve.
- Turn off "Automatically adjust brightness" in Display settings. Reports since macOS Tahoe suggest this option causes `CGSetDisplayTransferByTable` calls to be ignored.
- Don't run alongside other apps that manipulate the gamma table (BetterDisplay, MonitorControl, etc.). There are reports of abnormal brightness-control behavior on the monitor or MacBook display when combined.
- Not a precise calibration tool.

## Known issues

- Right after first selecting a new profile in System Settings, closing and reopening the laptop lid has been reported to reset the vcgt. Rebooting macOS resolves it.

## License

MIT License

## Author

[![Contributors](https://contrib.rocks/image?repo=wooooooooook/display-gamma-forge)](https://github.com/wooooooooook/display-gamma-forge/graphs/contributors)

## Support

[![Buy Me A Coffee](https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png)](https://buymeacoffee.com/wooooooooook)
