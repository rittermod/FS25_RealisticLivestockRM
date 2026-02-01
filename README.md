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
- Improved genetic inheritance with natural variation - offspring can now exceed or fall below parent trait values.


## Changelog
v0.5.0.0:
- Randomize father selection during breeding - eligible males are now chosen randomly instead of always the first one
- Improve genetic inheritance with natural variation - offspring can now exceed or fall below parent trait values
- Fix wrong text shown for straw in monitor menu
- Detect conflicting mods (e.g., MoreVisualAnimals) and show a unified conflict dialog at startup
- Add Italian translation (community contribution by @FirenzeIT)

v0.4.2.0:
- Fix multiplayer sync issues when subTypeIndex differs between server/client (PR by killemth)
- Add fallback for days per month calculation during early load (PR by killemth)
- Refactor subType resolution into helper function with logging

v0.4.1.0:
- Fix crash caused by invalid animal root node in some cases.
- Fix death message count for auto-sold newborns
- Fix wrong text for when females can reproduce

v0.4.0.0:
- Remove Font Library dependency by inlining the required functionality directly in the mod.
- Refactor file loading and source folder.
- Update mod icon.

v0.3.0.0:
- Add Highland Bulls based on Renfordt's PR in 389 Arrow-kb's original mod.

v0.2.0.0:
- Migrate savegames from Arrow-kb's Realistic Livestock to RitterMod version. To avoid conflits with original mod and other forks of it, this mod uses a different mod ID. Therefore, when you load a savegame that used the original Realistic Livestock mod, you will be prompted to migrate the data to this mod.

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

(I am not a OSS licensing lawyer, but most likeley neither are you. This is my understanding of the GPL-3 license as it applies to this mod. If you have **QUALIFIED** legal knowledge, and not armchair legal knowlege, that contradicts what I say here, please let me know.)
