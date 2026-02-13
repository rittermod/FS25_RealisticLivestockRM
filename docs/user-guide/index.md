# Realistic Livestock RM

A Farming Simulator 25 mod that replaces the default animal cluster system with individual animal simulation — each animal has unique genetics, health, and a full lifecycle.

> **Note:** This documentation was generated with AI assistance and may contain inaccuracies. If you spot an error, please [open an issue](https://github.com/rittermod/FS25_RealisticLivestockRM/issues).

## Key Features

- **Individual animals** — Every animal is unique with its own identity, genetics, and history
- **Genetics system** — Traits like productivity and size are inherited from parents with natural variation
- **Realistic breeding** — Gestation periods, offspring genetics, breeding age limits, and pregnancy complications
- **Disease simulation** — Species-specific diseases that spread, require treatment, and affect production
- **Lifecycle & aging** — Animals age, peak in productivity, grow old, and eventually die
- **Multiplayer support** — Full server/client synchronization

## Download

**[Latest release on GitHub](https://github.com/rittermod/FS25_RealisticLivestockRM/releases/latest)**

## Installation

1. Download the latest `FS25_RealisticLivestockRM.zip` from the link above
2. Place the ZIP file in your FS25 mods folder (do not extract it)
3. Enable the mod in the in-game mod manager

### Migrating from Arrow-kb's Realistic Livestock

If you previously used the original [FS25 Realistic Livestock](https://github.com/Arrow-kb/FS25_RealisticLivestock) mod, migration is automatic — just load your savegame and all animal data will be transferred.

## Compatibility

| | |
|---|---|
| **Game** | Farming Simulator 25 |
| **Multiplayer** | Supported (server-authoritative) |
| **Known conflicts** | FS25_MoreVisualAnimals, FS25_EnhancedLivestock, FS25_EnhancedAnimalSystem |

If a conflicting mod is detected, the game will show a warning dialog at startup.

## Documentation

**[Mod Overview](overview.md)** — How the mod works: what changes from vanilla FS25, how animals are tracked, and what to expect.

### Factsheets

Per-species reference with breeds, production, prices, breeding, and lifespan data:

- [Cattle](factsheet-cattle.md) — 7 breeds including dairy, beef, and highland
- [Pigs](factsheet-pigs.md) — 4 breeds with large litter mechanics
- [Sheep & Goats](factsheet-sheep.md) — 5 breeds covering wool, meat, and goat milk
- [Horses](factsheet-horses.md) — 8 colour variants, no diseases
- [Chickens](factsheet-chickens.md) — 3 breeds with egg production curves

### Guides

In-depth explanations of the mod's core systems:

- [Genetics](guide-genetics.md) — How traits work, inheritance, and the CVM gene
- [Breeding & Reproduction](guide-breeding.md) — Breeding requirements, gestation, lactation, and complications
- [Diseases](guide-diseases.md) — How diseases spread, treatment, immunity, and prevention

### Reference

- [Settings](reference-settings.md) — All configurable options with defaults and descriptions

## Credits

This mod is a fork of [FS25 Realistic Livestock](https://github.com/Arrow-kb/FS25_RealisticLivestock) by [Arrow-kb](https://github.com/Arrow-kb). Released under [GPL-3.0](https://github.com/rittermod/FS25_RealisticLivestockRM/blob/main/LICENSE).
