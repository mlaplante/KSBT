# Kroth's Scrolling Battle Text (KSBT)

Accurate floating combat text for World of Warcraft: Midnight, authored by **Kroth Haomarush**.

KSBT replaces the default floating combat text with a confidence-based attribution system — intelligently tracking outgoing damage, incoming damage, heals, and cooldowns with customizable scroll areas, fonts, and animations.

---

## Compatibility

- **WoW Version:** Midnight 12.0.1 (Interface 120001)
- **Addon Version:** 1.0.1

---

## Installation

1. Download the latest release from [GitHub Releases](https://github.com/mlaplante/KSBT/releases)
2. Extract the `KBST` folder to:
   ```
   World of Warcraft\_retail_\Interface\AddOns\KBST\
   ```
3. Restart WoW or type `/reload`

---

## Usage

| Command | Description |
|---------|-------------|
| `/ksbt` | Open configuration panel |
| `/krothsbt` | Open configuration panel (alternate) |
| `/ksbt debug [0-3]` | Set debug level (0=off, 3=verbose) |
| `/ksbt reset` | Reset profile to defaults |
| `/ksbt version` | Print current version |
| `/ksbt minimap` | Toggle minimap button visibility |

The minimap button also provides quick access:
- **Left-click** — Open config
- **Right-click** — Close config
- **Middle-click** — Toggle KSBT on/off

---

## Features

- Confidence-based damage/heal attribution
- Separate scroll areas for outgoing, incoming, and cooldown events
- Fully customizable fonts, sizes, colors, and animations
- Draggable scroll area positioning with unlock/lock mode
- Combat-only mode
- Ace3 config UI with profile support
- Minimap button

---

## Documentation

**Docs:** https://www.mintlify.com/mlaplante/KSBT

---

## Repository

**GitHub:** https://github.com/mlaplante/KSBT
**Author:** Kroth Haomarush
**Current Version:** 1.0.1
