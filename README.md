> [!NOTE]
> My version of the awesome [FS25 Realistic Livestock](https://github.com/Arrow-kb/FS25_RealisticLivestock) mod by [Arrow-kb](https://github.com/Arrow-kb).

# FS25 Realistic Livestock - Ritter version
This is a modified version of the [FS25 Realistic Livestock](https://github.com/Arrow-kb/FS25_RealisticLivestock) mod by [Arrow-kb](https://github.com/Arrow-kb) who has decided to stop all development of his mods.

The current goal of this version is to keep the core parts of the mod working for my use, and do the occasional fix or improvement that I feel is needed. 

Feel free to use it as you see fit, but please understand that this mod is way less ambitious than the original.


Main changes from the original mod:
- Automatically migrate savegame data from Arrow-kb's Realistic Livestock to this version.
- Added Highland Bulls based on Renfordt's PR 389 in Arrow-kb's original mod.
- Removed Font Library dependency by inlining the required functionality directly in the mod.


## Changelog

v0.4.0.0:
- Remove Font Library dependency by inlining the required functionality directly in the mod.
- Refactor file loading and source folder.
- Update mod icon.

v0.3.0.0:
- Add Highland Bulls based on Renfordt's PR in 389 Arrow-kb's original mod.

v0.2.0.0:
- Migrate savegames from Arrow-kb's Realistic Livestock to RitterMod version. To avoid conflits with original mod and other forks of it, this mod uses a different mod ID. Therefore, when you load a savegame that used the original Realistic Livestock mod, you will be prompted to migrate the data to this mod.