# Le Mechet Map Support

Realistic Livestock RM includes built-in support for the [Le Mechet](https://farming-simulator.com/mod.php?mod_id=357964) map by MA7Studio. When you load a savegame on Le Mechet, the mod automatically detects the installed map version and loads the matching configuration. No manual setup required.

> **Note:** This documentation was generated with AI assistance and may contain inaccuracies. If you spot an error, please [open an issue](https://github.com/rittermod/FS25_RealisticLivestockRM/issues).

---

## How It Works

The mod checks for Le Mechet at game start and reads the map's version number. If the version matches a tested configuration, everything loads seamlessly. If the map has been updated to a version the mod hasn't been tested with yet, you'll see a warning dialog with a link to report any problems.

You don't need to do anything - the detection and configuration loading is fully automatic.

## Supported Versions

| Map Version | Config | Status |
|-------------|--------|--------|
| 1.0.x | v1.0 | Tested |

If your version isn't listed and you see a warning dialog, please [open an issue](https://github.com/rittermod/FS25_RealisticLivestockRM/issues) so support can be added.

---

## What Le Mechet Adds

Le Mechet is a French-themed map. Like Witcombe, it adds new **breeds within the standard cow type** rather than new species. They share husbandry buildings, breeding mechanics, and lifecycle rules with the base-game and RLRM-bundled breeds.

Animals on Le Mechet carry an **FR eartag prefix** to reflect the map's country setting.

### New Breeds

| Animal Type | New Breed | Map Origin |
|-------------|-----------|-----------|
| **Cattle** | Charolaise | Le Mechet-defined |
| **Cattle** | Montbeliarde | Le Mechet-defined |
| **Cattle** | Simmental | Le Mechet-defined |
| **Cattle** | Vosgienne | Le Mechet-defined |

These breeds appear in the Animal Dealer alongside the base-game and RLRM breeds. Each one gets the full RLRM treatment: individual tracking, genetics, breeding, lifecycle, aging, and diseases.

### Males Added by the Mod

By default, the map only defines **female** versions of its new breeds. Without males, breeding wouldn't work for those breeds. The mod adds the matching bulls so natural reproduction is possible:

| Male Subtype | Animal Type | Mates With |
|--------------|-------------|-----------|
| **Charolais Bull** | Cattle | Charolaise cow (also pairs with other cow breeds, see Breeding Notes) |
| **Montbeliarde Bull** | Cattle | Montbeliarde cow (also pairs with other cow breeds) |
| **Simmental Bull** | Cattle | Simmental cow (also pairs with other cow breeds) |
| **Vosgienne Bull** | Cattle | Vosgienne cow (also pairs with other cow breeds) |

All bulls are buyable at the Animal Dealer and behave like any other RLRM bull - they cannot give birth themselves, but a healthy bull older than 12 months can mate with cows in the same husbandry. The 12-month gate matches every other RLRM cattle bull (Holstein, Angus, etc.); each Le Mechet breed's distinct character comes from gestation length and weights, not from when the bull becomes fertile.

---

## Breed Character on Le Mechet

Each Le Mechet breed has its own personality on the farm - different feed needs, milk output, gestation length, and sell prices. They all slot into the same lifecycle, breeding, and disease rules as everything else in RLRM, so they age and reproduce just like Holsteins or Limousins. The table below shows what makes each one distinct in the pasture.

| Breed | Distinctive in-game character |
|---|---|
| **Charolaise** | Heavy French beef breed - the largest of the four. Carries calves longer than the rest (14-month gestation vs the standard 10), so first calves arrive around 26 months - the slowest of the four. Premium pricing throughout: 300 / 6,600 to buy, peaks at 7,800 at 36 months. Heavy appetite to match - eats about two-thirds more than a Vosgienne does. Per RLRM convention, Charolaise still produces a modest dual-purpose milk every cow gets, but the breed character is "buy for beef, milk is bonus". |
| **Montbeliarde** | PDO Comte dairy breed. Standard 10-month gestation, first calf at 22 months (matches Holstein). Modest pricing (200 / 1,450) and a solid milk output peaking at 140 L/day. The most feed-efficient of the four - a lean dairy breed that delivers a modest milk yield on a small feed bill, the "lean dairy that also makes great cheese milk" angle. |
| **Simmental** | Dual-purpose Fleckvieh and the fastest-breeding of the four - 9-month heritage shorter gestation (unique on this map), so first calves arrive around 21 months. Pricing sits between dairy and beef (200 / 2,050 to buy, peaks at 2,500). Mid-range feed needs and a moderate milk peak (100 L/day). The compromise breed - works for either career path. |
| **Vosgienne** | Small mountain dairy - the rare endangered Vosges breed. Smallest frame of the four (target adult cow weight ~1/3 less than Charolaise). Standard 10-month gestation, first calf at 22 months. Modest pricing (190 / 1,900). Milk peak ~85 L/day - the "small farm efficiency" character. |
| **Hereford** | **Hidden** in the Animal Dealer on this map. Le Mechet ships no Hereford 3D model, so RLRM removes the buy option to avoid scrambled visuals. If you switch it back on in **Choose Animals For Sale**, the Hereford you buy shows another breed's model on this map. On any other map, Hereford is in the dealer as usual. |
| **Highland** *(DLC)* | Behaves the same as Highland on any other map - the standard RLRM Highland (12-month maturity, premium adult transport price, dual-purpose milk). RLRM corrects the visuals so the shaggy coat displays right on Le Mechet's husbandry. |
| **Brahman** *(DLC)* | **Hidden** in the Animal Dealer on this map, as Hereford is. Le Mechet's husbandry has no Brahman 3D model, so RLRM removes the buy option to avoid wrong visuals. If you switch it back on in **Choose Animals For Sale**, the Brahman you buy shows another breed's model on this map. On any other map, Brahman is in the dealer as usual. |

Bulls added by the mod mirror the cow of the same breed - see [Breeding Notes](#breeding-notes) below.

---

## Map-Native 3D Models

Unlike most map bridges, Le Mechet ships **its own custom cow models** for the four French breeds. So Charolaise actually looks like a Charolaise (cream-white heavy frame), Montbeliarde looks like a Montbeliarde (red-brown pied), and so on. You don't need an animal pack or texture mod - the breed-distinct visuals are built into Le Mechet itself.

Two model meshes are shared across breed pairs via texture tiles:

| Shared mesh | Used by | Coat colour |
|---|---|---|
| `cattleCharolaiseEtSimmental` | Charolaise + Simmental | Cream-white (Charolaise) / yellow-fawn pied (Simmental) |
| `cattleMontbeliardeEtVosgienne` | Montbeliarde + Vosgienne | Red-and-white pied (Montbeliarde) / black-and-white pied (Vosgienne) |

Each of the twelve age-stages (4 breeds x baby/kid/adult) has its own dealer-menu thumbnail so you can pick the right breed at the buy screen.

---

## Compatibility

> **NOT compatible with the [Cow Breeds Pack for RLRM](https://github.com/ConGan98/FS25_CowBreedsRLRM).** Both Le Mechet and the Cow Breeds pack replace the cow husbandry config to bring in their own 3D models. Only one can win at load time, and whichever one loses leaves its breeds with broken visuals (the affected animals exist as data but render as ghosts or fall back to wrong meshes). On Le Mechet maps, **disable the Cow Breeds pack**; on other maps, you can run the Cow Breeds pack normally.

RLRM now detects this combination and shows a warning dialog at startup naming the affected animal type, so you don't have to spot the broken visuals yourself.

This limitation comes from how FS25 loads animal models - it's the same reason two breed packs that target the same animal type can't both be active. See [Animal Packs > Not all packs are safe to combine](guide-animal-packs.md#not-all-packs-are-safe-to-combine) for the underlying mechanism.

---

## Breeding Notes

Le Mechet's new breeds breed the same way as any other RLRM breed:

- **Same-breed pairings** produce same-breed offspring. A Charolais bull and a Charolaise cow produce Charolaise calves.
- **Cross-breed pairings** produce mixed offspring whose breed follows the standard cross-breed rules. A Charolais bull and a Holstein cow can mate and will produce calves; the offspring breed is determined by the same rules used elsewhere in the mod.

Le Mechet does not enforce any "French-breeds-only" mating rule - its new breeds slot into the same cross-breed system that already governs Holstein/Angus/Limousin/etc.

If you want strict same-breed reproduction, keep one breed per husbandry. The sire is picked at random among the eligible males in the pen, so with mixed breeds you can't count on same-breed pairings.

**Bulls mirror the cow of the same breed.** Each Le Mechet bull takes on the heritage pricing, feed and water needs, and frame of his breed - a Charolais bull is priced like a heavy beef bull, while a Vosgienne bull is the smallest-frame of the four and a Montbeliarde bull is the most feed-efficient. All Le Mechet bulls become fertile at the RLRM-standard 12 months, the same as every other RLRM cattle bull. Bulls do not lactate, even when the cow has a milk curve.

---

## Related Pages

- [Breeding Guide](guide-breeding.md) - How breeding works for all supported animals
- [Genetics Guide](guide-genetics.md) - How traits are inherited
- [Cattle Factsheet](factsheet-cattle.md) - Production and breeding data for all cattle breeds
- [Animal Packs](guide-animal-packs.md) - Compatibility notes for breed packs
- [FAQ: Can you add more breeds?](faq.md#can-you-add-more-breeds-or-animal-types) - Why new breeds aren't created from scratch
