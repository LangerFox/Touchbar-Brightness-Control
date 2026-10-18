# Touchbar Brightness Control

<p align="center">
  <img src="icon_preview_1024.png" width="160" alt="Touchbar Brightness Control Icon">
</p>

A lightweight, native macOS menu bar utility that adds a **real-time Touch Bar brightness slider (`11.9 Nits` – `357.1 Nits`)** and fixes the bug where the Touch Bar gets stuck at minimum brightness after lid close/wake on MacBooks with a broken Ambient Light Sensor (ALS).

---

## 1. Features

* **Real-Time Brightness Slider**: Smoothly adjust Touch Bar brightness from `0%` (`11.9 Nits`) to `100%` (`357.1 Nits`) directly from the macOS menu bar, with live hardware Nits readout.
* **Quick Presets**: One-click buttons for `Min` (`11.9 Nits`), `25%` (`98.2 Nits`), `50%` (`184.5 Nits`, factory default), `75%` (`270.8 Nits`), and `Max` (`357.1 Nits`).
* **Broken ALS Wake Lock**: Automatically prevents macOS from dropping Touch Bar brightness to minimum when closing and reopening the lid.
* **Zero Background Overhead (`0 Hz` Polling)**: 100% event-driven architecture (`0.0%` idle CPU usage and `0` Idle Wakeups in Activity Monitor).
* **Launch at Login**: Built-in toggle to start automatically on login (with automatic `AppTranslocation` path resolution).

<p align="center">
  <img src="Screenshot.jpg" width="480">
</p>

---

## 2. Installation

### Option A: Download Prebuilt App
1. Download **`Touchbar-Brightness-Control-macOS-Universal.zip`** from this repository (or Releases) and extract **`Touchbar Brightness Control.app`**.
2. Drag **`Touchbar Brightness Control.app`** into your **`Applications`** folder and double-click to open it.
3. Go to **System Settings** -> **Privacy & Security**, scroll down to the **Security** section, and click **Open Anyway**.

### Option B: Build from Source
Requires Xcode Command Line Tools (`xcode-select --install`). No external dependencies:
```bash
git clone https://github.com/LangerFox/Touchbar-Brightness-Control.git
cd Touchbar-Brightness-Control
make
open "Touchbar Brightness Control.app"
```

---

## 3. Supported Devices

Compiled as a **Universal Binary (`arm64` + `x86_64`)** for macOS 12.0+:

* **Apple Silicon (13-inch MacBook Pro with Touch Bar — `A2338`)**:
  * MacBook Pro (13-inch, M1, 2020) — `MacBookPro17,1` (`A2338`) *(Tested & verified)*
  * MacBook Pro (13-inch, M2, 2022) — `Mac14,7` (`A2338`)
* **Intel (2016–2020 MacBook Pro with Touch Bar)**: **Untested** *(Compiled with `x86_64` support, but not tested on T1/T2 hardware — PRs welcome!)*

---

## 4. Why Does This Happen After Updating macOS?

If you replaced your MacBook Pro screen with a third-party display assembly—or if the top camera / Ambient Light Sensor (ALS) flex cable failed—you may notice a frustrating issue after updating to recent macOS versions (such as macOS 26.5+):

1. **Right after a reboot**, the Touch Bar lights up normally at its factory default brightness (`50%` / `184.5 Nits`).
2. **As soon as you close the lid and open it again (or wake from display sleep)**, the Touch Bar drops to its lowest possible brightness (`11.9 Nits`) and stays stuck there until you reboot.

Because macOS System Settings does not provide a manual Touch Bar brightness slider, there is no built-in way to bring the brightness back up once macOS dims it on wake.

---

## 5. Technical Deep Dive

Inside `/System/Library/PrivateFrameworks/CoreBrightness.framework`, `corebrightnessd` manages the main Retina display and the Touch Bar OLED (`AppleSummitLCD` / `CBDisplayModuleDFR`) as two separate display containers inside `BLControl`:

* On the **main Retina display**, when no ALS (`AppleSPUALSDriver`) service is registered, macOS sets `CBAutoBrightnessAvailable = 0` and `CBAutoBrightnessEnabled = 0`, disabling auto-brightness cleanly.
* On the **Touch Bar (`CBDisplayModuleDFR`)**, even when `CBAutoBrightnessModuleDFR` reports `BLControlAlsSupported = 0`, `CBDisplayModuleDFR` still defaults to **`DisplayBrightnessAuto = 1`**.
* On a fresh boot, the DFR display controller initializes the OLED panel at its hardware midpoint (`DisplayPanelLuminanceMid = 184.5 Nits`). Meanwhile, `AABC::FirstALSSampleTimeout()` inside `CBAutoBrightnessModuleDFR` times out waiting for a non-existent sensor (`"TIMEOUT!! - Potentially busted ALS?"`), leaving its internal trusted ambient illuminance (`_Esensor_trusted`) uninitialized at **`0.0f`**.
* The moment the display wakes from sleep (`displayLogicalStatePropertyHandler:` / `displayStatePropertyHandler:`), `AABC::SetDisplayFactor(1.0)` evaluates `AABC::IlluminanceToLuminance(0.0f)` against the DFR auto-brightness curve, clamping the Touch Bar down to index `0` of `NitsToUserBrightnessTable`:
  ```text
  DisplayBrightness = {
      Brightness = 0;
      Nits = "11.89999";
      NitsPhysical = "11.89999";
  };
  ```

### How `Touchbar Brightness Control` Solves It

`Touchbar Brightness Control` communicates directly with `CoreBrightness.framework`'s private `BrightnessSystemClient` API:
```objc
[self.bscClient setProperty:@NO forKey:@"DisplayBrightnessAuto"];
[self.bscClient setProperty:@(val) forKey:@"DisplayBrightness"];
```
To achieve `0.0%` idle CPU usage without polling timers, the app sleeps in kernel `mach_msg2_trap` and relies on an event-driven pipeline with built-in safeguards:
1. **Event-Driven Wake & XPC Hooks**: Subscribes to `CoreBrightness` XPC notifications (`registerNotificationBlock:forProperties:`), `NSWorkspaceDidWakeNotification` / `NSWorkspaceScreensDidWakeNotification`, and `CGDisplayRegisterReconfigurationCallback`.
2. **Sleep-State Suppression**: Tracks `NSWorkspaceWillSleepNotification` and `NSWorkspaceScreensDidSleepNotification` so it never fights `corebrightnessd` while the lid is closed or the panel is powered down.
3. **Self-Write Echo Suppression & Burst Rate-Limiting**: Ignores XPC echo notifications within a `0.25s` window (`kSelfWriteIgnoreWindow`) after its own writes, checks that hardware brightness actually drifted beyond step-quantization tolerance (`> 6%`), and enforces a rate limit (`>= 0.5s` interval, max `3` restores per `5s` window).
4. **Native `SMAppService` & `AppTranslocation` Login Item Support**: Registers via macOS 13+ `SMAppService.mainAppService` when installed normally, and falls back to `SecTranslocateCreateOriginalPathForURL` (`Security.framework`) + `LaunchAgents` so `Launch at Login` always records the real on-disk `.app` path even if first launched from a translocated quarantine mount.

> **TL;DR**: Dead ALS = macOS thinks you live in a pitch-black cave (`0 Lux`) every time you open the lid, nuking your Touch Bar down to `11.9 Nits` with no settings slider to turn it back up.  
> This app tells `CoreBrightness` to shut up, gives you a manual slider, and forces your Touch Bar to stay bright.

---
README by Gemini 4 Argon, LangerFox

Icon by LangerFox

## License

MIT License
