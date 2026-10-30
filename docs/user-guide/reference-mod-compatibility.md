# Mod Compatibility

Realistic Livestock RM rewrites the animal system from the ground up. That makes it incompatible with many other mods that change the same systems, and gives it sharp edges when paired with mods that modify animal data. This page lists the mods RLRM blocks or warns you about at startup, plus mods that load but have known limitations. That a mod is NOT on this list does NOT mean that it is tested and confirmed to work. 

> **Note:** This documentation was generated with AI assistance and may contain inaccuracies. If you spot an error, please [open an issue](https://github.com/rittermod/FS25_RealisticLivestockRM/issues).

---

## Blocking Conflicts

These mods cannot run alongside Realistic Livestock RM. They either replace the same animal system entirely, were originally derived from the original FS25_RealisticLivestock, or break RLRM's core animal feeding loop.

If any of these mods is enabled when you start the game, RLRM detects them, shows a **Mod Conflict Detected** dialog, and forces a restart. Disable the conflicting mod (or RLRM) and try again.

| Mod | Reason |
|-----|--------|
| **FS25_RealisticLivestock** | The original Arrow-kb mod that RLRM forks. Both replace the cluster-based animal system. |
| **FS25_MoreVisualAnimals** | Extracted subset of RL's visual changes. Overlapping animation and visual hooks. |
| **FS25_EnhancedLivestock** | Another version of the original mod. |
| **FS25_EnhancedAnimalSystem** | Extensive changes to the animal system that conflict with RLRM. |
| **FS25_AnimalFoodCalculator** | Breaks the core animal loop with RLRM: blocks food and water intake and halts milk, egg, and wool output, plus a significant performance impact that grows with herd size. A dismissible warning proved insufficient for a silent husbandry break. |

If you previously played with **FS25_RealisticLivestock** (the original), RLRM migrates your savegame automatically the first time you load it - just disable the old mod and enable RLRM in its place.

---

## Partial Compatibility

These mods load and run alongside RLRM, but one or more of their features do not work because of how they interact with RLRM's rewritten animal system. RLRM does not necessarily detect these mods or warn you about them at startup - the rest of the mod keeps working, so you can keep using it as long as you avoid the affected feature. The specific limitation is listed per mod.

| Mod | Limitation |
|-----|-----------|
| **FS25_lsfmAnimalTransportPack.zip** | The LSFM Animal Transport Pack's animal herding / driving feature does not work. Driving animals opens the RL Menu at that pen instead of the pack's transfer screen, so animals cannot be moved to or from the pack's carrier. There may be further errors later in the process. The rest of the pack is unaffected. This pack is distributed with the Hof Bergmann map, so it may be active even if you did not install it separately - see [Hof Bergmann Map Support](map-hof-bergmann.md#bundled-animal-transport-pack). |

---

## Known-Working Integrations

These mods are confirmed to work alongside RLRM:

| Mod | Notes |
|-----|-------|
| **Seasonal Wool Production** | Works with RLRM via a built-in compatibility shim. |
| **Extended Production Point / EPP butchers** | Basic support. EPP butchers accept RLRM animals. |

---

## Reporting a Missing Entry

Spotted a mod that conflicts with RLRM but isn't listed here? Or a mod that this page flags but actually works fine for you?

[Open an issue on GitHub](https://github.com/rittermod/FS25_RealisticLivestockRM/issues) with:

- The other mod's name and version
- A short description of what goes wrong (or works) when both are enabled
- Whether the mod is on the official ModHub or hosted elsewhere

The list above is updated as new conflicts and integrations are discovered.

---

## Related Pages

- [Settings Reference](reference-settings.md) - Every configurable mod option
- [FAQ](faq.md) - Common questions about mod scope and compatibility
