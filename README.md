# 🩺 HealerProtection

A lightweight healer alert addon for **Octo WoW / Vanilla WoW 1.12.1**.

HealerProtection automatically warns your group when you are:

* 💧 Running low on mana
* 🫗 Out of mana
* ❤️ Close to death
* 💀 Dead
* 👹 Taking aggro

The addon was adapted and optimized specifically for the **Vanilla 1.12.1 client used by Octo WoW**.

## ✨ Features

* 💧 Low Mana warning
* 🫗 Out of Mana warning
* ❤️ Near Death warning
* 💀 Death notification
* 👹 Aggro warning
* 💬 Optional chat messages
* 🎭 Optional emotes
* 🎚️ Configurable mana and health thresholds
* 📢 Configurable announcement channel
* 👀 Optional Line of Sight warning
* 🌍 Optional announcements outside instances
* ⚔️ Battleground filtering
* 🛡️ Raid filtering
* ✏️ Custom message prefix and suffix

Open the settings panel with:

```text
/hp
```

or:

```text
/healerprotection
```

## 🐙 Octo WoW Compatibility

HealerProtection is designed for:

```text
World of Warcraft 1.12.1
Octo WoW
```

The addon does **not require** ClassicAPI, SuperWoW or Nampower.

If additional APIs such as `UnitThreatSituation()` are available through the client or another extension, HealerProtection can automatically use them to improve aggro detection.

## 👹 Aggro Detection

Vanilla WoW does not provide the same threat API available in modern versions of the game.

HealerProtection therefore uses several methods:

* `UnitThreatSituation()` when available
* Your current hostile target
* The hostile targets selected by party members
* The hostile targets selected by raid members

This improves aggro detection while keeping the addon compatible with the Vanilla 1.12.1 client.

## ⚡ Performance

HealerProtection is designed to be extremely lightweight.

Mana, health and death monitoring are **event-driven**, which means the addon only reacts when the relevant game state changes.

Aggro detection uses a small periodic check because Vanilla does not provide a reliable native threat event.

When Aggro alerts are disabled, the aggro check is effectively skipped.

## 📦 Installation

1. Download the addon.
2. Extract the archive.
3. Place the `HealerProtection` folder inside:

```text
World of Warcraft\Interface\AddOns\
```

Your folder structure should look like:

```text
Interface
└── AddOns
    └── HealerProtection
        ├── HealerProtection.toc
        └── core.lua
```

4. Restart the game.
5. Enable **HealerProtection** in the AddOns menu.
6. Type `/hp` to configure the addon.

## ⚙️ Default Settings

```text
Out of Mana: Enabled
OOM threshold: 10%

Low Mana: Enabled
Low Mana threshold: 30%

Near Death: Enabled
Near Death threshold: 30%

Death message: Enabled

Aggro warning: Disabled

Show in raids: Enabled
Show outside instances: Disabled
Show in battlegrounds: Disabled

Announcement channel: AUTO
```

`AUTO` automatically selects the most appropriate group channel:

```text
PARTY → while in a party
RAID  → while in a raid
```

The addon will not attempt to send invalid PARTY, RAID or GUILD messages when the corresponding channel is unavailable.

## 🔇 Anti-Spam

Mana and health alerts include a reset margin.

For example, after triggering a Low Mana warning, your mana must recover above the configured threshold before the warning can trigger again.

This prevents repeated messages when your mana or health constantly moves around the alert threshold.

## 🆕 Version 1.1

### Improvements

* ❤️ Restored the Near Death alert
* 🎚️ Added configurable Near Death threshold
* 👹 Improved aggro detection
* 👥 Added party and raid target scanning
* ⚡ Converted mana and health monitoring to event-driven checks
* 🧹 Reduced unnecessary polling
* 🔇 Added anti-spam logic for mana and health alerts
* 💬 Centralized chat channel validation
* 🐙 Improved Octo WoW / Vanilla 1.12.1 compatibility
* 🔓 Removed unnecessary `InCombatLockdown()` dependency
* 🧽 Removed obsolete setup and bootstrap code
* 🗑️ Removed obsolete `SETOOMP` handling
* 🔌 Removed unnecessary ClassicAPI, SuperWoW and Nampower dependencies
* 👀 Added Line of Sight warning to the settings menu
* 🧠 Improved Lua 5.0 / Vanilla event compatibility
* 💾 Preserved compatibility with existing `HPTABPC` saved variables

## ⌨️ Commands

```text
/hp
/healerprotection
```

Both commands open or close the configuration window.

## 💾 Saved Variables

Settings are stored per character using:

```text
HPTABPC
```

Existing settings from older versions are preserved whenever possible.

## 👤 Author

HealerProtection is maintained by **Dusk92** and adapted for the **Octo WoW / Vanilla 1.12.1** environment.

## 🐛 Bug Reports

If you encounter a bug or unexpected behavior on Octo WoW, feel free to open an issue on GitHub.

Please include:

* 📝 What happened
* 🎯 What you expected to happen
* ⚙️ Your enabled HealerProtection settings
* 🔌 Whether you use SuperWoW / ClassicAPI
* ❗ Any Lua error message you received
