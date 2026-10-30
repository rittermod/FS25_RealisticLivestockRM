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
| **Cattle** | Charolais | Le Mechet-defined |
| **Cattle** | Montbeliarde | Le Mechet-defined |
| **Cattle** | Simmental | Le Mechet-defined |
| **Cattle** | Vosgienne | Le Mechet-defined |

These breeds appear in the Animal Dealer alongside the base-game and RLRM breeds. Each one gets the full RLRM treatment: individual tracking, genetics, breeding, lifecycle, aging, and diseases.

### Males Added by the Mod

By default, the map only defines **female** versions of its new breeds. Without males, breeding wouldn't work for those breeds. The mod adds the matching bulls so natural reproduction is possible:

| Male Subtype | Animal Type | Mates With |
|--------------|-------------|-----------|
| **Charolais Bull** | Cattle | Charolais cow (also pairs with other cow breeds, see Breeding Notes) |
| **Montbeliarde Bull** | Cattle | Montbeliarde cow (also pairs with other cow breeds) |
| **Simmental Bull** | Cattle | Simmental cow (also pairs with other cow breeds) |
| **Vosgienne Bull** | Cattle | Vosgienne cow (also pairs with other cow breeds) |

All bulls are buyable at the Animal Dealer and behave like any other RLRM bull: a healthy bull older than 12 months can mate with cows in the same husbandry. The 12-month gate matches every other RLRM cattle bull (Holstein, Angus, etc.); each Le Mechet breed's distinct character comes from gestation length, feed needs and milk, not from when the bull becomes fertile.

---

## Breed Character on Le Mechet

Each Le Mechet breed has its own personality on the farm - different feed needs, milk output, gestation length, and sell prices. They all slot into the same lifecycle, breeding, and disease rules as everything else in RLRM, so they age and reproduce just like Holsteins or Limousins. The table below shows what makes each one distinct in the pasture.

| Breed | Distinctive in-game character |
|---|---|
| **Charolais** | French beef breed. Carries calves longer than the rest (14-month gestation vs the standard 10), so first calves arrive around 27 months - the slowest of the four. Premium pricing throughout: sale value peaks at 7,800 at 36 months. Heavy appetite - eats about two-thirds more than a Vosgienne does. RLRM gives it a dual-purpose milk curve peaking at 265 L/month, nearly double Montbeliarde's 140, but the breed character is "buy for beef, milk is bonus". |
| **Montbeliarde** | PDO Comte dairy breed. Standard 10-month gestation, first calf at 23 months (matches Holstein). Modest pricing (sale value peaks at 1,500 at 36 months) and a solid milk output peaking at 140 L/month. The most feed-efficient of the four - a lean dairy breed that delivers a modest milk yield on a small feed bill, the "lean dairy that also makes great cheese milk" angle. |
| **Simmental** | Dual-purpose Fleckvieh and the fastest-breeding of the four - 9-month heritage shorter gestation (unique on this map), so first calves arrive around 22 months. Pricing sits between dairy and beef (sale value peaks at 2,500 at 36 months). Mid-range feed needs and a moderate milk peak (100 L/month). The compromise breed - works for either career path. |
| **Vosgienne** | Mountain dairy - the rare endangered Vosges breed. Standard 10-month gestation, first calf at 23 months. Sale value peaks at 2,250 at 36 months. Milk peak ~85 L/month - the "small farm efficiency" character. |
| **Hereford** | **Hidden** in the Animal Dealer on this map. Le Mechet ships no Hereford 3D model, so RLRM removes the buy option to avoid scrambled visuals. If you switch it back on in **Choose Animals For Sale**, the Hereford you buy shows another breed's model on this map. On any other map, Hereford is in the dealer as usual. |
| **Highland** *(DLC)* | Behaves the same as Highland on any other map - the standard RLRM Highland (12-month maturity, standard cattle transport fee, dual-purpose milk). RLRM corrects the visuals so the shaggy coat displays right on Le Mechet's husbandry. |
| **Brahman** *(DLC)* | **Hidden** in the Animal Dealer on this map, as Hereford is. Le Mechet's husbandry has no Brahman 3D model, so RLRM removes the buy option to avoid wrong visuals. If you switch it back on in **Choose Animals For Sale**, the Brahman you buy shows another breed's model on this map. On any other map, Brahman is in the dealer as usual. |

*Food, water, straw and production figures are per in-game month, whatever your month length. The animal's info box shows them per day, so with 3 days per month it shows a third of these figures.*

Prices on this page are sale values. The dealer's price is the animal's own sale value plus a markup that depends on the [**Dealer Animal Quality**](reference-settings.md#dealer-ai) setting, plus a transport fee per animal, so a breed that sells high also costs more to buy. Buying into a trailer at the dealer has no transport fee.

Bulls added by the mod mirror the cow of the same breed - see [Breeding Notes](#breeding-notes) below.

---

## Map-Native 3D Models

Unlike most map bridges, Le Mechet ships **its own custom cow models** for the four French breeds. So Charolais actually looks like a Charolais (cream-white), Montbeliarde looks like a Montbeliarde (red-and-white pied), and so on. You don't need an animal pack or texture mod - the breed-distinct visuals are built into Le Mechet itself.

Two model meshes are shared across breed pairs via texture tiles:

| Shared by | Coat colour |
|---|---|
| Charolais + Simmental | Cream-white (Charolais) / yellow-fawn pied (Simmental) |
| Montbeliarde + Vosgienne | Red-and-white pied (Montbeliarde) / black-and-white pied (Vosgienne) |

Each of the twelve age-stages (4 breeds x baby/kid/adult) has its own dealer-menu thumbnail so you can pick the right breed at the buy screen.

---

## Compatibility

> **NOT compatible with the [Cow Breeds Pack for RLRM](https://github.com/ConGan98/FS25_CowBreedsRLRM).** Both Le Mechet and the Cow Breeds pack replace the cow husbandry config to bring in their own 3D models. Only one can win at load time, and whichever one loses leaves its breeds with broken visuals (the affected animals exist as data but render as ghosts or fall back to wrong meshes). The Cow Breeds pack has dropped Le Mechet support, so no version of it works here. On Le Mechet maps, **disable the Cow Breeds pack**; on other maps, you can run the Cow Breeds pack normally.

RLRM now detects this combination and shows a warning dialog at startup naming the affected animal type, so you don't have to spot the broken visuals yourself.

This limitation comes from how FS25 loads animal models - it's the same reason two breed packs that target the same animal type can't both be active. See [Animal Packs > Not all packs are safe to combine](guide-animal-packs.md#not-all-packs-are-safe-to-combine) for the underlying mechanism.

---

## Breeding Notes

Le Mechet's new breeds breed the same way as any other RLRM breed:

- **Same-breed pairings** produce same-breed offspring. A Charolais bull and a Charolais cow produce Charolais calves.
- **Cross-breed pairings** produce mixed offspring whose breed follows the standard cross-breed rules. A Charolais bull and a Holstein cow can mate and will produce calves; the offspring breed is determined by the same rules used elsewhere in the mod.

Le Mechet does not enforce any "French-breeds-only" mating rule - its new breeds slot into the same cross-breed system that already governs Holstein/Angus/Limousin/etc.

If you want strict same-breed reproduction, keep one breed per husbandry. The sire is picked at random among the eligible males in the pen, so with mixed breeds you can't count on same-breed pairings.

**Bulls mirror the cow of the same breed.** Each Le Mechet bull takes on the heritage pricing and the feed and water needs of his breed - a Charolais bull is priced like a heavy beef bull, while a Vosgienne bull is the smallest-frame of the four and a Montbeliarde bull is the most feed-efficient. All Le Mechet bulls become fertile at the RLRM-standard 12 months, the same as every other RLRM cattle bull.

---

## Related Pages

- [Breeding Guide](guide-breeding.md) - How breeding works for all supported animals
- [Genetics Guide](guide-genetics.md) - How traits are inherited
- [Cattle Factsheet](factsheet-cattle.md) - Production and breeding data for all cattle breeds
- [Animal Packs](guide-animal-packs.md) - Compatibility notes for breed packs
- [FAQ: Can you add more breeds?](faq.md#can-you-add-more-breeds-or-animal-types) - Why new breeds aren't created from scratch
