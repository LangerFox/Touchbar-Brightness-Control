# TouchBarBright — Native macOS Touch Bar Brightness Slider & Broken ALS Wake-Dimming Fix

A lightweight (`~100 KB`), zero-polling (`0.0%` idle CPU, `0` idle wakeups), pure Objective-C/AppKit menu bar utility for MacBook Pro models with a Touch Bar (2016–2020 Intel & 2020–2022 Apple Silicon M1/M2 13-inch).

It gives you a **real-time hardware Nits brightness slider (`11.9 Nits` – `357.1 Nits`)** in the macOS top menu bar and fixes the infamous **macOS Touch Bar minimum-brightness lock bug** on MacBooks with a broken or disconnected Ambient Light Sensor (ALS) after third-party screen replacements.

---

## The Bug: Why Does the Touch Bar Get Stuck at Minimum Brightness After Lid Close/Wake?

If you replaced your MacBook Pro screen with a third-party display assembly (or if the top camera / Ambient Light Sensor flex cable lost power), you may notice a frustrating issue on recent macOS releases (macOS Sequoia / macOS 26.5+):

1. **Right after a reboot**, the Touch Bar lights up at normal brightness (`50%` / `184.5 Nits`).
2. **As soon as you close the lid and open it again (or wake from display sleep)**, the Touch Bar drops to its dimmest possible level and stays stuck there until you reboot.

### Root Cause (Reverse-Engineered from `CoreBrightness.framework`)

Inside `/System/Library/PrivateFrameworks/CoreBrightness.framework`, macOS manages the main Retina display and the Touch Bar OLED (`AppleSummitLCD` / `CBDisplayModuleDFR`) as two separate display containers inside `BLControl`:

* On the **main Retina display**, when no ALS (`AppleSPUALSDriver`) is present, macOS sets `CBAutoBrightnessAvailable = 0` and `CBAutoBrightnessEnabled = 0`, disabling auto-brightness cleanly.
* On the **Touch Bar (`CBDisplayModuleDFR`)**, even when `CBAutoBrightnessModuleDFR` reports `BLControlAlsSupported = 0`, `CBDisplayModuleDFR` still defaults to **`DisplayBrightnessAuto = 1`**.
* When the Mac boots, the DFR display controller (`AppleMobileADBE0`) initializes the OLED panel at its hardware midpoint (`DisplayPanelLuminanceMid = 184.5 Nits`).
* However, the moment the display wakes from sleep (`displayLogicalStatePropertyHandler:`), `CBAutoBrightnessModuleDFR` evaluates the current ambient light reading. Because the ALS is dead/disconnected, the reading is **`0 Lux` (pitch black)**, causing `CoreBrightness` to slam the Touch Bar down to index `0` of `NitsToUserBrightnessTable`:
  ```text
  DisplayBrightness = {
      Brightness = 0;
      Nits = "11.89999";
      NitsPhysical = "11.89999";
  };
  ```
* Because Apple removed the manual Touch Bar brightness slider from macOS System Settings, there is no built-in UI to recover from `11.89999 Nits` without rebooting.

---

## How `TouchBarBright` Fixes It

`TouchBarBright` communicates directly with `CoreBrightness.framework`'s `BrightnessSystemClient` interface:
```objc
[client setProperty:@NO forKey:@"DisplayBrightnessAuto"];
[client setProperty:@(targetBrightness) forKey:@"DisplayBrightness"];
```

### Key Features

* **Real-Time Native Slider (`NSSlider`)**: Smoothly adjust Touch Bar brightness from `0%` (`11.9 Nits`) to `100%` (`357.1 Nits`) with live hardware Nits feedback.
* **5 One-Click Presets**: `Min` (`11.9 Nits`), `25%` (`98.2 Nits`), `50%` (`184.5 Nits`, factory default), `75%` (`270.8 Nits`), and `Max` (`357.1 Nits`).
* **100% Event-Driven Wake Guard (`0 Hz` Polling)**:
  * Subscribes to `CoreBrightness` XPC property notifications (`registerNotificationBlock:forProperties:`), `NSWorkspaceDidWakeNotification`, `NSWorkspaceScreensDidWakeNotification`, and `CGDisplayRegisterReconfigurationCallback`.
  * Uses **zero timers** when idle: `0.0%` CPU usage and `0` Idle Wakeups in Activity Monitor.
* **Launch at Login**: Built-in one-click toggle that manages `~/Library/LaunchAgents/com.lfx.TouchBarBright.plist`.
* **Universal Binary (`arm64` + `x86_64`)**: Runs natively on M1/M2 13-inch MacBook Pros (`A2338`) and 2016–2020 Intel Touch Bar MacBook Pros.

---

## Installation & Building from Source

### Option 1: Download Prebuilt Universal App
1. Download `TouchBarBright-macOS-Universal.zip` from Releases and extract `TouchBarBright.app`.
2. Move `TouchBarBright.app` to `/Applications`.
3. If macOS Gatekeeper prompts that the app is ad-hoc signed, run:
   ```bash
   xattr -cr /Applications/TouchBarBright.app
   open /Applications/TouchBarBright.app
   ```

### Option 2: Build from Source (Requires Xcode Command Line Tools)
The entire application is contained in a single ~250-line Objective-C file (`TouchBarBright.m`) with zero external dependencies:
```bash
git clone https://github.com/YOUR_USERNAME/TouchBarBright.git
cd TouchBarBright
make
open TouchBarBright.app
```

---

## 繁體中文說明 (Traditional Chinese)

### 為什麼換過副廠螢幕／壞掉環境光感測器 (ALS) 後，Touch Bar 只要蓋上再打開就會變最暗？

在 2020 M1 MacBook Pro (`A2338`) 或其他配備 Touch Bar 的機型上，如果頂部的環境光感測器（ALS）因更換副廠螢幕總成或排線損壞而斷電，在升級到較新的 macOS（例如 macOS 26.5+）後會遇到一個頑固 Bug：
* **剛重開機時**：Touch Bar 顯示控制器預設以原廠中間值 **`50%` (`184.5 Nits`)** 點亮，一切正常。
* **只要把螢幕蓋上再打開（或休眠喚醒）**：macOS 底層的 `CoreBrightness.framework` (`CBAutoBrightnessModuleDFR`) 會在喚醒時重新讀取 ALS 照度；因為感測器斷電回傳 `0 Lux`（全黑），系統就會把 Touch Bar 強制壓到最低的第 0 階（**`Brightness = 0` / `11.89999 Nits`**），而且因為 macOS 早已移除手動調整 Touch Bar 亮度的設定，除非重開機否則永遠無法恢復亮度。

### `TouchBarBright` 功能特色
1. **macOS 原生頂層選單列 (Menu Bar) 無段滑桿**：隨時拉動滑桿即時調整 Touch Bar 亮度（`11.9 Nits` ～ `357.1 Nits`），並提供 `Min` / `25%` / `50% (原廠 184.5 Nits)` / `75%` / `Max` 五顆快速鍵。
2. **純事件驅動開蓋防暗守護 (`0 Hz` 零輪詢)**：完全不採用 Timer 輪詢，平時休眠於核心 `mach_msg2_trap`（CPU 佔用率 `0.0%`、Idle Wakeups 為 `0`），只在螢幕喚醒或 `corebrightnessd` 重置亮度時瞬間介入鎖定亮度並關閉 `DisplayBrightnessAuto`。
3. **一鍵開機自啟 (`Launch at Login`)**：直接在選單內打勾即可自動寫入 `~/Library/LaunchAgents`。

---

## License

MIT License
