# Witcombe Map Support

Realistic Livestock RM includes built-in support for the [Witcombe](https://oxygendavid.itch.io/witcombe-park-farm) map. When you load a savegame on Witcombe, the mod automatically detects the installed map version and loads the matching configuration. No manual setup required.

> **Note:** This documentation was generated with AI assistance and may contain inaccuracies. If you spot an error, please [open an issue](https://github.com/rittermod/FS25_RealisticLivestockRM/issues).

---

## How It Works

The mod checks for Witcombe at game start and reads the map's version number. If the version matches a tested configuration, everything loads seamlessly. If the map has been updated to a version the mod hasn't been tested with yet, you'll see a warning dialog with a link to report any problems.

You don't need to do anything - the detection and configuration loading is fully automatic.

## Supported Versions

| Map Version | Config | Status |
|-------------|--------|--------|
| 1.0 up to (not including) 1.4 | v1.0 | Tested |

If your version isn't listed and you see a warning dialog, please [open an issue](https://github.com/rittermod/FS25_RealisticLivestockRM/issues) so support can be added.

---

## What Witcombe Adds

Witcombe is a UK-themed map. Unlike Hof Bergmann - which adds entirely new animal *species* (ducks, geese, alpacas) - Witcombe adds new **breeds within the standard cow, pig, and sheep types, plus Witcombe's own rabbit type**. They share husbandry buildings, breeding mechanics, and lifecycle rules with the base-game and RLRM-bundled breeds.

Animals on Witcombe carry a **UK eartag prefix** to reflect the map's country setting.

### New Breeds

| Animal Type | New Breed | Map Origin |
|-------------|-----------|-----------|
| **Cattle** | Jersey | Witcombe-defined |
| **Pigs** | Gloucestershire Old Spot | Witcombe-defined |
| **Sheep** | Texel | Witcombe-defined |
| **Sheep** | Suffolk | Witcombe-defined |
| **Sheep** | Blue Faced Leicester | Witcombe-defined |

These breeds appear in the Animal Dealer alongside the base-game and RLRM breeds. Each one gets the full RLRM treatment: individual tracking, genetics, breeding, lifecycle, aging, and diseases.

### Males Added by the Mod

By default, the map only defines **female** versions of its new breeds. Without males, breeding wouldn't work for those breeds. The mod adds the matching males so natural reproduction is possible:

| Male Subtype | Animal Type | Mates With |
|--------------|-------------|-----------|
| **Jersey Bull** | Cattle | Jersey cow (also pairs with other cow breeds, see Breeding Notes) |
| **Gloucestershire Old Spot Boar** | Pig | GOS sow (also pairs with other pig breeds) |
| **Texel Ram** | Sheep | Texel ewe (also pairs with other sheep breeds) |
| **Suffolk Ram** | Sheep | Suffolk ewe (also pairs with other sheep breeds) |
| **Blue Faced Leicester Ram** | Sheep | BFL ewe (also pairs with other sheep breeds) |
| **Buck Rabbit** | Rabbit | Doe rabbit |

All males are buyable at the Animal Dealer and behave like any other RLRM male: a healthy male older than the breeding age can mate with females in the same husbandry.

---

## Breed Character on Witcombe

Each Witcombe breed has its own personality on the farm - different feed needs, milk output, gestation length, and sell prices. They all slot into the same lifecycle, breeding, and disease rules as everything else in RLRM, so they age and reproduce just like Holsteins or Landraces. The table below shows what makes each one distinct in the pasture.

| Breed | Distinctive in-game character |
|---|---|
| **Jersey** | Heritage dairy breed. Drinks about 60% of the water of a Holstein, eats less feed, and produces less milk at peak (~160 L/month vs ~255 for Swiss Brown). 9-month gestation (one month shorter than other cattle), premium calf and adult prices. Sells best young at 24 months. |
| **Hereford** | Leaner heritage beef breed. 9-month gestation, premium sell prices while young, and an earlier sell-price peak at 24 months (vs 36 months for other beef breeds). Eats less than a Limousin and still gives more milk at peak (~265 L/month) than a Swiss Brown (~255) or a Jersey (~160). |
| **Highland** *(DLC)* | Behaves the same as Highland on any other map - the standard RLRM Highland (12-month maturity, standard cattle transport fee, dual-purpose milk). |
| **Gloucestershire Old Spot** | Heritage slow-grow pig. Reaches breeding age at 8 months instead of 6, grows on a slower curve with a 10-month extension, and commands premium pricing. Won't fatten as fast as a Landrace but sells for more. |
| **Texel** | Meat sheep. Drinks and eats more than the other Witcombe heritage sheep. A ewe's sell price climbs steadily from about 600 at 8 months to 1,200 at 36 months; a ram's doubles just after 8 months. Lower wool yield than a wool breed (peak ~25), and lambs aren't sheared before 6 months. |
| **Suffolk** | Meat sheep with mid-range feed needs among the Witcombe sheep. Sell price climbs quickly to about 550 at 6 months, then keeps rising to 1,100 at 36 months. Wool peak ~35 (between Texel and base-game). |
| **Blue Faced Leicester** | Breeding-stock sheep with modest sell prices (peaks at 700 at 36 months) - buy for breeding, not for the meat market. Feed-efficient. Shorter 4-month gestation, unique among Witcombe sheep. |
| **Rabbit** | Witcombe-defined species. Most map values are kept as authored; the mod corrects rabbit-scale weights, litter size (usually 4, rarely up to 8), and doe consumption rates so the animals are viable to keep (see [Rabbit Improvements](#rabbit-improvements)). |

*Food, water, straw and production figures are per in-game month, whatever your month length. The animal's info box shows them per day, so with 3 days per month it shows a third of these figures.*

Prices on this page are sale values. The dealer's price is the animal's own sale value plus a markup that depends on the [**Dealer Animal Quality**](reference-settings.md#dealer-ai) setting, plus a transport fee per animal, so a breed that sells high also costs more to buy. Buying into a trailer at the dealer has no transport fee.

Bulls, boars, and rams added by the mod mirror the female of the same breed - see [Breeding Notes](#breeding-notes) below.

---

## Hereford on Witcombe

Hereford exists in RLRM out of the box, but Witcombe ships its own Hereford visuals and a heritage breed character that's worth surfacing.

**Visual fix.** Out in the pasture, Witcombe's Hereford already displays in its correct brown-and-white Hereford colouring - no model or texture remapping is needed. The mod only swaps the Animal Dealer thumbnails to Witcombe's own custom Hereford images, so the buy screen matches what you see in the field.

**Heritage breed character.** On Witcombe, Hereford also feels like a traditional UK heritage breed:

- **9-month gestation** (one month shorter than the standard 10).
- **Premium sell prices while young.** A calf starts at 250 (vs 210 for RLRM's default Hereford) and a 24-month cow is worth 3,500 (vs 2,200). The dealer's price follows the sale value, so she costs more to buy at those ages too.
- **Leaner appetite** - lower feed, water, and manure rates than other beef cattle.
- **Earlier sell-price peak.** Cows hit 2,500 at 18 months and peak at 3,500 at 24 months - one year earlier than other beef breeds, which peak at 36 months. Bulls follow the same shape with bigger numbers (3,000 / 4,200 at 18 / 24 months).

The bull mirrors the cow's heritage pricing and lean efficiency. RLRM's standard cattle behaviour also applies on top - 12-month breeding age, the standard cattle transport fee, and RLRM's dual-purpose milk, which peaks at about 265 L/month for this breed.

You don't need to do anything - both the visual fix and the heritage profile are applied automatically.

---

## Shared 3D Models for New Breeds

The base game's cow / pig / sheep configs don't include 3D models for Jersey, Gloucestershire Old Spot, Texel, Suffolk, or Blue Faced Leicester. To make these breeds buyable and visible at all, the mod reuses the **in-pasture mesh and texture** of an existing breed. Texel and Blue Faced Leicester keep their own breed-specific dealer thumbnails; the rest reuse the donor's thumbnail too:

| New breed | Reuses visuals from | Affects |
|-----------|---------------------|---------|
| Jersey | Swiss Brown | Cow + bull |
| Gloucestershire Old Spot | Black Pied | Sow + boar |
| Texel | Landrace | Ewe + ram |
| Suffolk | Steinschaf | Ewe + ram |
| Blue Faced Leicester | Landrace | Ewe + ram |

So a Jersey cow on Witcombe is rendered as a Swiss Brown cow - both in the Animal Dealer thumbnail and in the pasture. The breed name, prices, food and water consumption, milk yield, and breeding parameters are all Jersey-specific, so simulation-wise it's a distinct breed; visually it's identical to its donor. See [Breed Character on Witcombe](#breed-character-on-witcombe) for the per-breed differences.

This is the same approach RLRM uses for its own bundled subtypes that lack dedicated models. It's the lightest way to give a new breed full RLRM treatment when nobody is shipping custom 3D textures for it.

> **Want breed-distinct visuals?** Install an animal pack that ships its own textures. The `FS25_CowBreedsRLRM` pack is one example - it bakes a custom cattle texture atlas (Jersey, Red Holstein, Ayrshire, Guernsey, Hereford, Charolais, and more) onto the base-game meshes, so each of its breeds renders in its own coat colour. It adds its own Jersey beside Witcombe's as a separate breed, and it covers cattle only, so Witcombe's pigs and sheep keep their shared models. See [Animal Packs](guide-animal-packs.md) for installation and compatibility notes.

---

## Rabbit Improvements

The map's default rabbit data is derived from 3D model dimensions, which produces unrealistic values. The mod corrects:

| What's Corrected | Why |
|------------------|-----|
| Female weight to 0.1 / 2.5 / 5.0 kg (min/target/max) | Map derived weight from navigation mesh size, not real rabbit weight |
| Doe water and food consumption to rabbit-scale rates (0.1-0.5 L water, 0.2-1.5 L food per month) | Map's source values were sheep-scaled and would crash doe Health to 0% within hours of placement |
| Male weight to 0.1 / 3.0 / 5.5 kg | Same weight correction for the new male subtype |
| Litter size to usually 4 kits per pregnancy, rarely up to 8 | Map default was usually 1, at most 3; real rabbits have 4-8 per litter |
| Male breeding age set to 4 months | Real rabbits mature at 3-4 months |
| Fertility curve added for rabbits (breeding from about 5 months, ending around 5 years) | Without it, does would not conceive until about 13 months |

Buck rabbits are also added by the mod - without them, only the female could reproduce (parthenogenetically), which is replaced with proper male/female breeding.

---

## Breeding Notes

Witcombe's new breeds breed the same way as any other RLRM breed:

- **Same-breed pairings** produce same-breed offspring. A Jersey bull and a Jersey cow produce Jersey calves.
- **Cross-breed pairings** produce mixed offspring whose breed follows the standard cross-breed rules. A Jersey bull and a Holstein cow can mate and will produce calves; the offspring breed is determined by the same rules used elsewhere in the mod.

Witcombe does not enforce any "Jersey-only" or "UK-only" mating rule - its new breeds slot into the same cross-breed system that already governs Holstein/Angus/Hereford/etc.

If you want strict same-breed reproduction, keep one breed per husbandry. The sire is picked at random among the eligible males in the pen, so with mixed breeds you can't count on same-breed pairings.

**Males mirror their female of the same breed.** Bulls, boars, and rams added by the mod take on the heritage pricing and the feed and water needs of their breed - a Jersey bull is priced like a heritage Jersey rather than a generic dairy bull, a Texel ram is the heaviest of the three rams, a Blue Faced Leicester ram is the lightest and feed-efficient. Rams use the same wool curve as the ewe of the same breed, including the delay before lambs are old enough to shear.

---

## Related Pages

- [Breeding Guide](guide-breeding.md) - How breeding works for all supported animals
- [Genetics Guide](guide-genetics.md) - How traits are inherited
- [Cattle Factsheet](factsheet-cattle.md) - Production and breeding data for all cattle breeds
- [Pigs Factsheet](factsheet-pigs.md) - Pig breed reference
- [Sheep Factsheet](factsheet-sheep.md) - Sheep and goat breed reference
- [FAQ: Can you add more breeds?](faq.md#can-you-add-more-breeds-or-animal-types) - Why new breeds aren't created from scratch
