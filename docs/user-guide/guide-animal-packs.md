# Animal Packs

Animal packs are third-party mods that extend Realistic Livestock RM with new breeds or adjusted animal balance. They're standard FS25 mods that RLRM discovers and loads automatically when enabled alongside the main mod.

> **Note:** This documentation was generated with AI assistance and may contain inaccuracies. If you spot an error, please [open an issue](https://github.com/rittermod/FS25_RealisticLivestockRM/issues).

---

## Available Packs

Community packs built for RLRM:

- [Cow Breeds Pack for RLRM](https://github.com/ConGan98/FS25_CowBreedsRLRM) by ConGan98 - additional cattle breeds
- [Sheep Breeds Pack for RLRM](https://github.com/ConGan98/FS25_SheepBreedsRLRM) by ConGan98 - additional sheep breeds

RLRM doesn't verify or endorse third-party packs - see [Before You Install](#before-you-install).

---

## What Packs Can Do

There are two kinds of animal packs:

**Balance packs** adjust numbers on existing breeds -- prices, food consumption, production rates, reproduction timing. They don't add new breeds or change how animals look. A balance pack is a lightweight way to tweak the simulation to your preference.

**Breed packs** add entirely new breeds with custom 3D models, textures, and store images. They can also include custom fill types and translations. A breed pack is a more substantial addition that introduces new animals to the game.

Both types can be combined -- a single pack might add new breeds and also adjust properties on existing ones.

---

## Installing a Pack

1. Download the pack (it's a standard FS25 mod ZIP file)
2. Place it in your mods folder
3. Enable it in the mod manager alongside Realistic Livestock RM
4. Start your game

That's it. RLRM detects the pack automatically and loads it during game start. No configuration, no XML editing, no manual setup.

---

## Before You Install

Animal packs modify the same simulation data that RLRM carefully tunes for realistic behavior. They can be powerful, but they come with important caveats.

### Pack quality varies

RLRM doesn't verify or endorse third-party packs. A well-made pack enhances gameplay. A poorly made one can cause anything from unrealistic animal behavior to game errors. Check whether the pack author is known in the community and whether other players have tested it.

### Not all packs are safe to combine

How well packs work together depends on what kind of changes they make:

| Combination | Result |
|-------------|--------|
| Multiple balance packs | Generally safe. They only conflict if two packs change the exact same property on the exact same breed - in that case, the last one loaded wins silently. |
| Balance pack + breed pack | Safe. Balance packs don't touch models or visuals. |
| Breed packs for **different** animal types (e.g., one adds cow breeds, another adds pig breeds) | Safe. They modify separate parts of the simulation. |
| Breed packs for the **same** animal type (e.g., two cow breed packs) | **Will likely conflict.** Breed packs that add new visuals need to replace the model configuration for that animal type. Only one pack can do this - the second one overwrites the first, which can break the first pack's breeds (wrong textures, missing visuals, or errors). |
| Map with map-native cattle/pig/sheep models + breed pack for the **same** animal type | **Will conflict.** A map that ships its own animal models replaces the model configuration the same way a breed pack does. Only one can win. Known case: [Le Mechet](map-le-mechet.md) (map-native French cattle models) is not compatible with the [Cow Breeds Pack for RLRM](https://github.com/ConGan98/FS25_CowBreedsRLRM), which has dropped Le Mechet support - on Le Mechet maps, disable the Cow Breeds pack. |
| Cow breed pack that replaces the cow model configuration without Brahman models + Brahman *(Beans and Alpacas DLC)* | **Brahman has no model.** Brahman animals are invisible in pens until the pack adds Brahman models. Known case: the [Cow Breeds Pack for RLRM](https://github.com/ConGan98/FS25_CowBreedsRLRM) today. |

RLRM now detects when two packs override the same animal type's model configuration. When it does, it shows a warning dialog at game start and writes a matching warning to the log naming the conflicting packs in load order, so you can tell at a glance which packs collided and which one won.

### Don't stack blindly

Each pack adds complexity to the simulation. More packs does not automatically mean better gameplay -- it means more moving parts that can interact in unexpected ways. Start with one pack, verify it works with your map and mod setup, then add more if needed.

### Test before committing

Try new packs in a test save first, especially breed packs. If something goes wrong in your main save, it may be difficult to undo.

---

## How Packs Load

- RLRM scans all enabled mods at game start, looking for packs
- Packs are loaded in **alphabetical order** by mod name
- If two packs change the same property on the same breed, the alphabetically later mod name wins (for example, `FS25_RLRM_B` loads after `FS25_RLRM_A`)
- Packs can add new breeds and override existing properties, but **cannot remove** existing breeds from the game. That is a limit on packs rather than on the player - the **Choose Animals For Sale** setting hides any breed or age group from the dealer, whether it came from a pack or the base game (admin only in multiplayer)

---

## Verifying a Pack Loaded

Check the game log for messages like:

- `MapBridge: Animal pack 'Pack Name' v1.0 by Author DETECTED (FS25_ModName)` -- a DETECTED line naming the pack, its version, and author
- `Animal pack 'Pack Name' activated` -- the pack loaded successfully

If the pack adds new breeds, they should appear in the animal dealer - unless you have hidden them with the **Choose Animals For Sale** setting, which applies to pack breeds exactly as it does to built-in ones. Open that selector to check before assuming a pack failed to load. Balance changes (prices, food consumption, etc.) take effect immediately with no visual indication -- check the animal details screen to verify values match what you expect.

---

## If Something Goes Wrong

1. **Disable packs one at a time** to isolate which one causes the problem
2. **Check the game log** for warnings or errors mentioning "MapBridge" or "Animal pack"
3. **Report issues to the pack author**, not to RLRM -- unless the problem persists with all packs disabled

---

## For Pack Creators

If you're a modder interested in creating your own animal pack, see the [Creating Animal Packs](guide-creating-packs.md) technical reference.
