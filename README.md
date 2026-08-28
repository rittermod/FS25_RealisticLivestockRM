[![Read User Guide](https://img.shields.io/badge/Read-User_Guide-blue?style=for-the-badge&logo=materialformkdocs&logoColor=white)](https://rittermod.github.io/FS25_RealisticLivestockRM/)
[![Download Latest Release](https://img.shields.io/badge/Download-Latest_Release-orange?style=for-the-badge&logo=github)](https://github.com/rittermod/FS25_RealisticLivestockRM/releases/latest/download/FS25_RealisticLivestockRM.zip)



> [!NOTE]
> My version of the awesome [FS25 Realistic Livestock](https://github.com/Arrow-kb/FS25_RealisticLivestock) mod by [Arrow-kb](https://github.com/Arrow-kb).

# FS25 Realistic Livestock - Ritter version

Replaces FS25's simple animal clusters with individually tracked animals - each with unique genetics, breeding, diseases, and production traits. A maintained version of Arrow-kb's [Realistic Livestock](https://github.com/Arrow-kb/FS25_RealisticLivestock) mod.

Every animal is tracked separately with its own identity, genetic makeup, health status, and production output. Genetics are inherited through breeding, diseases can spread and require treatment, and production is driven by each animal's individual traits. Everything is managed from the RL Menu - a dedicated tabbed interface for browsing, trading, moving, filtering, and automating your herds.

This is a maintained version of the original mod by Arrow-kb, who has discontinued development. The goal is to keep the mod working, fix bugs, and make improvements where needed. While less ambitious in scope than the original roadmap, this version focuses on stability and reliability.

**[User Documentation](https://rittermod.github.io/FS25_RealisticLivestockRM/)** - Guides and per-species factsheets covering genetics, breeding, diseases, production, and settings.

## Features

- Individual animal tracking with unique identity (farm ID, unique ID, birthday)
- Genetics system with heritable traits that affect production output
- Genetics display in animal names with configurable detail level (average score or full trait breakdown)
- Breeding and reproduction with pregnancy mechanics and genetic inheritance
- AI insemination system with semen dewars
- Disease simulation with infection, immunity, and treatment charged as a monthly fee
- Animal monitoring to track individual animals over time
- Weight system tied to genetics and feeding
- Animal marking and castration
- RL Menu: a standalone tabbed menu (default Right Shift + O, also opened from pens, dealers, and trailers) covering all animal management - animal browsing with pedigree/genetics/disease detail, moving, selling, buying, AI straw purchases, messages, and trailer loading/unloading
- Saveable animal filters: build reusable filters in-game (age, gender, pregnancy, genetics, weight, health, and more) and cycle them with F across the menu tabs
- Herdsman automation: named daily tasks (sell, buy, castrate, naming, AI insemination, move, horse care) driven by saved filters, with per-task caps, budgets, and a herdsman wage
- Animal Country of Origin setting: choose the country new animals are registered in (ear tags, identifiers)
- Dealer controls: choose which animals and age groups the dealer offers, and whether it stocks Budget, Standard or Premium quality animals
- Daily summary mode for message log
- In-game help pages covering monitors, pregnancy, production, weight, and genetics
- Highland cattle bull support
- Animal pack system: third-party mods can add new breeds or adjust animal balance
- Map support: Hof Bergmann (ducks, geese, cats, rabbits, alpacas, quail) with automatic version-aware compatibility
- Map support: Witcombe (UK breeds - Jersey, Gloucestershire Old Spot, Texel, Suffolk, Blue Faced Leicester, plus Hereford heritage profile) with automatic version-aware compatibility
- Map support: Le Mechet (French breeds - Charolaise, Montbeliarde, Simmental, Vosgienne) with automatic version-aware compatibility
- Simple support for butchers using Extended Production Point (EPP) mod
- Mod compatibility checks at startup: hard-block dialog for incompatible mods, plus a dismissible warning tier for mods known to degrade gameplay
- In-game warning when two map bridges or animal packs replace the same animal type's husbandry config (last-loaded wins; first one's animals can render as ghosts)
- Mod compatibility bridges for foreign mods that overlap RLRM's hooks - currently coexists with Seasonal Wool Production (Argsy Gaming) without double wool output
- Multiplayer support (server-authoritative)

## Supported Maps & Packs

**Maps:**
- [Hof Bergmann](https://www.lsfarming-mods.com/) - ducks, geese, cats, rabbits, alpacas, quail with full breeding support
- [Witcombe](https://oxygendavid.itch.io/witcombe-park-farm) - UK breeds (Jersey, Gloucestershire Old Spot, Texel, Suffolk, Blue Faced Leicester) with full breeding support; Hereford heritage profile
- [Le Mechet](https://farming-simulator.com/mod.php?mod_id=357964) - French breeds (Charolaise, Montbeliarde, Simmental, Vosgienne) with full breeding support (NOT compatible with Cow Breeds Pack unless you use the latest development version - both replace the cow husbandry config)

**Animal Packs:**
- [Cow Breeds Pack for RLRM](https://github.com/ConGan98/FS25_CowBreedsRLRM) by ConGan98 - additional cattle breeds
- [Sheep Breeds Pack for RLRM](https://github.com/ConGan98/FS25_SheepBreedsRLRM) by ConGan98 - additional sheep breeds

## Notes

- Based on Arrow-kb's Realistic Livestock mod (v1.2.0.5), released under GPL-3 license
- Savegame data from Arrow-kb's original version is automatically migrated on first load
- Font Library mod is no longer required (functionality has been inlined)
- Incompatible with FS25_EnhancedLivestock, FS25_MoreVisualAnimals, and FS25_EnhancedAnimalSystem (use FS25_MoreVisualAnimalsRM instead of FS25_MoreVisualAnimals)

## Installation

Place `FS25_RealisticLivestockRM.zip` in your mods folder.

**Migrating from Arrow-kb's version:** Remove `FS25_RealisticLivestock.zip` and `FS25_FontLibrary.zip`. Back up your savegame first, then load it - data migrates automatically.

## Changelog
See the [CHANGELOG](CHANGELOG.md) for a detailed list of changes, fixes, and improvements in this version.

## License
This mod is released under GPL-3 license. See the [LICENSE](LICENSE) file for details.




# About reuse, modification and building upon the original Realistic Livestock mod by Arrow-kb

> [!NOTE]
> TL;DR: The original Realistic Livestock mod by Arrow-kb is open source GPL-3 licensed. Anyone can freely use, modify, and redistribute it as long as they: give credit, keep the same GPL-3 license, and share their changes openly. No one can restrict reuse.



The original Realistic Livestock mod by Arrow-kb is released under GPL-3 license. This means that anyone are free to reuse and modify the mod (the work) as long as they comply with the terms of the GPL-3 license, which in short terms means, to the best of my understanding:
- You are free to use, reuse, and modify the code/mod for any purpose.
- You must provide attribution to the author(s) when you distribute reused/modified/built upon code.
- You must release your own modified code/mod under the same GPL-3 license so others can build upon it too.
- You must include a copy of the GPL-3 license with the mod.

This means that **anyone can use, and build upon, any modification I make** in this Ritter version of the Realistic Livestock mod **without any prior consent** or similar **from me, as long as they too comply with the GPL-3 license terms**, attibute me for the changes I have made AND release their modified code/mod under the same GPL-3 license for any changes/additions they have made.

It **also means** that **anyone, including me, can reuse and build opon any changes made by others** to the mod **without any prior consent** or similar **from the authors of those modifications** since their changes to the mod are also licensed under the same GPL-3.

**Nobody can say, "No, this is my code, you can not reuse it".** The GPL-3 license ensures that the code/mod and any mod built on it will always remain free and open for anyone to use, modify, and distribute under the same GPL-3 license terms. There might at some point a discussion about when is a mod no longer a "mod built on the original mod" but that is way over my paygrade.

And **remember**: Any vioation of this might not be intentional or malicious. People might simply not understand the implications of what they agreed to when they started building upon the mod with this license.

(I am not a OSS licensing lawyer, but most likeley neither are you. This is my understanding of the GPL-3 license as it applies to this mod. If you have **QUALIFIED** legal knowledge, and not armchair legal knowledge, that contradicts what I say here, please let me know.)
