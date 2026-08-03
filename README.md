# 📺 Custom Android TV IPTV Player

A lightweight, high-performance **Flutter IPTV Player** specifically built and optimized for low-spec Android TV boxes, Smart TVs, and Leanback devices (such as Wisdom Share, Allwinner, and Amlogic hardware).

---

## ✨ Features

- ⚡ **Low-Bandwidth Optimized:** Smooth stream initialization and smart buffer handling designed for lower-speed networks.
- 🔄 **Smart Channel Recovery:** Automatically categorizes failing/offline streams into an **"Unavailable"** tab and auto-restores them once back online.
- 🎮 **Full D-Pad Remote Navigation:** Native arrow-key traversal, instant channel zapping (CH ▲/▼), and TV-friendly interface.
- 🔁 **Dynamic Auto-Retry Overlay:** Professional error handling with dynamic countdown reconnect loops—no manual button mashing required.
- ⭐ **Enhanced Favorites UI:** Dedicated TV-safe favorite toggling and instant category filtering.
- 🛡️ **Double-Back Exit Protection:** Prevents accidental app closes with double-tap back verification on the home screen.
- 🌐 **Anti-Block Stream Engine:** Injected User-Agent headers to bypass standard stream blocks (HTTP 400/403).

---

## 📦 How to Install

1. Go to the **[Releases](../../releases)** section on the right side of this repository.
2. Download the latest `app-armeabi-v7a-release.apk` (for budget TV boxes) or `app-release.apk`.
3. Transfer the file to a USB flash drive and insert it into your TV Box.
4. Open your TV Box File Manager, select the `.apk` file, and install!

---

## 🛠️ Built With

* **Framework:** [Flutter](https://flutter.dev/)
* **Language:** Dart
* **Target OS:** Android TV / Leanback (Android 5.0+)
