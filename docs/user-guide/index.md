# Realistic Livestock RM

A Farming Simulator 25 mod that replaces the default animal cluster system with individual animal simulation - each animal has unique genetics, health, and a full lifecycle.

> **Note:** This documentation was generated with AI assistance and may contain inaccuracies. If you spot an error, please [open an issue](https://github.com/rittermod/FS25_RealisticLivestockRM/issues).

## Key Features

- **Individual animals** - Every animal is unique with its own identity, genetics, and history
- **Genetics system** - Traits like productivity and size are inherited from parents with natural variation
- **Realistic breeding** - Gestation periods, offspring genetics, breeding age limits, and pregnancy complications
- **Disease simulation** - Species-specific diseases that make animals sick and cut production and value - most spread through a pen and can be treated
- **Lifecycle & aging** - Animals age, peak in productivity, grow old, and eventually die
- **Herd automation** - Set daily tasks that sell, buy, move, castrate, name, or inseminate animals for you
- **Saved filters** - Build reusable searches to find and act on exactly the animals you want
- **Multiplayer support** - Full server/client synchronization

## Download

**[Latest release on GitHub](https://github.com/rittermod/FS25_RealisticLivestockRM/releases/latest)**

## Installation

1. Download the latest `FS25_RealisticLivestockRM.zip` from the link above
2. Place the ZIP file in your FS25 mods folder (do not extract it)
3. Enable the mod in the in-game mod manager

### Migrating from Arrow-kb's Realistic Livestock

If you previously used the original [FS25 Realistic Livestock](https://github.com/Arrow-kb/FS25_RealisticLivestock) mod, migration is automatic - just load your savegame and all animal data will be transferred.

## Compatibility

| | |
|---|---|
| **Game** | Farming Simulator 25 |
| **Multiplayer** | Supported (server-authoritative) |
| **Compatibility** | see [Mod Compatibility](reference-mod-compatibility.md) for blocking conflicts and performance warnings. |

### Map Support

RLRM works on virtually any map out of the box - it does not need to be on a supported list. The maps below are the ones that add their own custom animal types or breeds; for those, the mod auto-detects the map and its installed version and loads matching support so the custom animals also get full genetics and breeding.

- **[Hof Bergmann](map-hof-bergmann.md)** - Ducks, geese, cats, rabbits, alpacas, and quail fully supported with breeding, genetics, and reproduction
- **[Witcombe](map-witcombe.md)** - UK breeds (Jersey, Gloucestershire Old Spot, Texel, Suffolk, Blue Faced Leicester) fully supported with breeding, genetics, and reproduction. Hereford also gets a heritage breed profile. Adds rabbit keeping with breeding support.
- **[Le Mechet](map-le-mechet.md)** - French breeds (Charolaise, Montbeliarde, Simmental, Vosgienne) with their map-native 3D models, fully supported with breeding, genetics, and reproduction

If a map updates to an untested version, you'll see a warning at game start - you're encouraged to report any issues.

### Mod Compatibility

- **FS25_ExtendedProductionPoint (EPP)** - Basic support for butchers using the EPP mod
- **Animal Packs** - Third-party mods can add new breeds or adjust animal balance. See [Animal Packs](guide-animal-packs.md).

## Documentation

**[Mod Overview](overview.md)** - How the mod works: what changes from vanilla FS25, how animals are tracked, and what to expect.

### Factsheets

Per-species reference with breeds, production, prices, breeding, and lifespan data:

- [Cattle](factsheet-cattle.md) - 7 breeds including dairy, beef, and highland
- [Pigs](factsheet-pigs.md) - 3 breeds with large litter mechanics
- [Sheep & Goats](factsheet-sheep.md) - 4 sheep breeds plus goats covering wool, meat, and goat milk
- [Horses](factsheet-horses.md) - 8 colour variants with riding, fitness and cleanliness
- [Chickens](factsheet-chickens.md) - Hens and roosters with egg production curves

### Guides

In-depth explanations of the mod's core systems:

- [Genetics](guide-genetics.md) - How traits work, inheritance, and the CVM gene
- [Breeding & Reproduction](guide-breeding.md) - Breeding requirements, gestation, lactation, and complications
- [Diseases](guide-diseases.md) - How diseases spread, treatment, immunity, and prevention
- [Saved Filters](guide-saved-filters.md) - Build reusable animal filters and use them in-game
- [Herdsman Automation](guide-herdsman.md) - Automate daily herd chores with rules

### Map Support

- [Hof Bergmann](map-hof-bergmann.md) - Exotic animals, supported versions, and known limitations
- [Witcombe](map-witcombe.md) - UK breeds, supported versions, and the Hereford heritage profile
- [Le Mechet](map-le-mechet.md) - French breeds, supported versions, and the Hereford-hidden / Highland-remap caveats

### Customization

- [Animal Packs](guide-animal-packs.md) - Third-party packs for new breeds and balance adjustments
- [Creating Packs](guide-creating-packs.md) - Technical reference for pack creators

### FAQ

- [Frequently Asked Questions](faq.md) - Common questions about genetics, breeding, and the mod

### Reference

- [Settings](reference-settings.md) - All configurable options with defaults and descriptions
- [Breeding Stats](reference-breeding.md) - Per-species breeding ages, gestation, and fertility windows
- [Mod Compatibility](reference-mod-compatibility.md) - Blocking conflicts and performance warnings

## Credits

This mod is a fork of [FS25 Realistic Livestock](https://github.com/Arrow-kb/FS25_RealisticLivestock) by [Arrow-kb](https://github.com/Arrow-kb). Changes to the disease system are inspired by Renfordt's [Enhanced Livestock](https://github.com/renfordt/FS25_EnhancedLivestock), with some parts converted directly from it. Released under [GPL-3.0](https://github.com/rittermod/FS25_RealisticLivestockRM/blob/main/LICENSE).
