# ESP32 Agent — Privacy Policy

Last updated: 2026-10-15

ESP32 Agent is an open-source app that lets an AI model of your choice operate your iPhone through a small
ESP32 USB board. The developer runs no servers for it and receives no data from it.

## What the app does with your data

- **Screen and run data.** To decide each step, the app sends screenshots of your iPhone screen and your task
  text to the model endpoint **you** set up (a cloud API or your own server). That provider's privacy policy
  applies to those requests. If you enable optional remote management, the configured service receives
  connection status and task progress, and authorized operators can request current screenshots and logs.
  The separate local task debugging switch lets an authenticated computer submit task text and receive
  task outcomes, which may contain text read from the screen. Use only test pages in this mode.
- **On your iPhone only.** Runs (steps, model replies, screenshots, screen video), the debug log and crash
  reports from iOS are stored in the app's own storage. The Wi-Fi video reader can cache up to 64 MiB of
  H.264 reference pictures locally to recover after relaunch; deleting a run does not erase that cache.
  Removing the app removes its local run and cache files.
- **API key.** Your model API key is stored in the iOS Keychain on this device and is never written to logs
  or exports.
- **Bluetooth and Wi-Fi.** The app connects to the ESP32 board over Bluetooth and may join the board's own
  Wi-Fi hotspot. It does not scan for or record other devices or networks.
- **Sharing.** Exports mask the top of screenshots, not the content below it. Review screenshots and task
  text before sharing them. Authorized operators may also retrieve screenshots or logs when remote management is enabled.

## What the app does not do

No accounts, no analytics, no advertising, no tracking, and no third-party SDKs. The app does not collect
data for the developer.

## Apple

If you install a TestFlight build or allow "Share with App Developers" in iOS settings, Apple may pass crash
reports and usage statistics to the developer under Apple's own privacy policy.

## Contact

Open an issue at https://github.com/onehumanbeing/esp32-iphone-agent/issues.
