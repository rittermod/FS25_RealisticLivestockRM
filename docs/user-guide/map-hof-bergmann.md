# Hof Bergmann Map Support

Realistic Livestock RM includes built-in support for the [Hof Bergmann](https://www.lsfarming-mods.com/filebase/filebase/27-maps/) map. When you load a savegame on Hof Bergmann, the mod automatically detects the installed map version and loads the matching configuration. No manual setup required.

> **Note:** This documentation was generated with AI assistance and may contain inaccuracies. If you spot an error, please [open an issue](https://github.com/rittermod/FS25_RealisticLivestockRM/issues).

---

## How It Works

The mod checks for Hof Bergmann at game start and reads the map's version number. If the version matches a tested configuration, everything loads seamlessly. If the map has been updated to a version the mod hasn't been tested with yet, you'll see a warning dialog with a link to report any problems.

You don't need to do anything - the detection and configuration loading is fully automatic.

## Supported Versions

| Map Version | Config | Status |
|-------------|--------|--------|
| 1.3.0.1 up to (not including) 1.4 | v1.3 | Tested |
| Any 1.4.x (including Beta 1 and Beta 2) | v1.4 | Tested |

The mod accepts a whole range of versions for each configuration, not just the exact numbers above. Only a map version that falls **outside** these ranges triggers the warning dialog.

If your version isn't covered and you see a warning dialog, please [open an issue](https://github.com/rittermod/FS25_RealisticLivestockRM/issues) so support can be added.

---

## Exotic Animals

Hof Bergmann adds several animal types beyond the base game. The mod gives most of these animals full RLRM treatment: individual tracking, genetics, breeding, lifecycle, and aging. Ducks are kept as a kind of chicken, so both avian flu strains can reach them; the other exotic animals catch none of the mod's diseases.

Animals on Hof Bergmann carry a **DE (Germany) eartag prefix** to reflect the map's country setting.

### What the Bridge Adds

For each exotic animal type, the mod adds **male subtypes** so that natural breeding is possible. Without the bridge, these types only have females that spontaneously reproduce.

| Animal Type | Subtypes Added | Breeding |
|-------------|---------------|----------|
| **Ducks** | Drake (male) | Ducks and drakes breed naturally |
| **Geese** | Gander (male) | Geese and ganders breed naturally |
| **Cats** | Tomcat (male) | Cats and tomcats breed naturally |
| **Rabbits** | *(male already exists)* | Breeding age corrected |
| **Alpacas** *(v1.4+)* | 4 male colour variants | Cross-colour breeding supported |
| **Quail** *(v1.4+)* | Male quail | Quail breed naturally |

All exotic animals can be bought, sold, bred, monitored, and managed through the livestock menu just like base game animals.

> **Wild Ducks:** On v1.4 the bridge adds a buyable wild-duck drake and a wild-duck breeding group. However, the map has no duck husbandry building, so wild ducks stay dealer-only - you can see them at the livestock dealer, but they cannot be placed or managed on the map.

### Corrections Applied

The map's default animal data is derived from 3D model dimensions, which sometimes produces unrealistic values. The bridge corrects these:

| Animal | What's Corrected | Why |
|--------|-----------------|-----|
| **Geese** | Weight reduced from ~90 kg to 5-8 kg | Map derived weight from navigation mesh size, not real goose weight |
| **Rabbits** | Weight refined to 2.5-5.5 kg | Same navigation mesh issue |
| **Rabbits** | Male breeding age set to 6 months | Map default was 18 months; real rabbits mature at 3-4 months |
| **Cats** | Litter size increased to 3-6 kittens | Map default was 1-3; real cats have 3-5 per litter |
| **Geese** | Clutch size set to 3-6 eggs | Map default was 1-3 |
| **Rabbits** | Litter size increased to 4-8 kits | Map default was 1-3; real rabbits have 4-8 per litter |

---

## Horses

Hof Bergmann uses its own horse 3D models with separate foal and adult stages, which differs from the base game's single-model layout. The bridge remaps RLRM's horse breeds to HB's model system so that breed colours display correctly and foals properly transition to adult models at 12 months.

### Available Breeds

HB has native 3D models for 4 of RLRM's 8 horse breeds. The other 4 are disabled at the dealer since they don't have matching models on this map.

| Breed | Available at Dealer | Notes |
|-------|:---:|-------|
| **Gray** | Yes | Native HB breed |
| **Palomino** | Yes | Native HB breed |
| **Black** | Yes | Native HB breed |
| **Seal Brown** | Yes | Native HB breed |
| **Pinto** | No | Uses Gray model in-game |
| **Chestnut** | No | Uses Seal Brown model in-game |
| **Bay** | No | Uses Seal Brown model in-game |
| **Dun** | No | Uses Palomino model in-game |

If you already have Pinto, Chestnut, Bay, or Dun horses in a savegame, they continue to load and function normally -- they just use a visually similar breed's 3D model.

### Riding and Equipment (v1.4)

On HB v1.4, horses are fully rideable and compatible with the Horse Addon Pack. Saddles, carriages, and tools attach correctly to all breeds.

---

## Cow Milk on Pastures

On Hof Bergmann, the cow pasture buildings collect milk as **milk cans** (physical pallets that spawn at the building) rather than filling a milk tank. Every RLRM cow breed produces cans here - including the beef breeds - so a whole mixed herd contributes.

> **Milk cans ignore lactation.** Everywhere else in RLRM a cow only gives milk while lactating (the 10 months after calving), and non-lactating cows give zero - see the [Cattle Factsheet](factsheet-cattle.md#milk-production-by-breed). The can-collecting cow buildings are the exception: they produce cans for **every adult cow** (from 12 months) regardless of lactation, following the cow's age curve instead of the lactation cycle. A dry cow, or a heifer that has never calved, will still fill cans. This matches how the map's own cow buildings behaved before RLRM.

If your cow building fills a **milk tank** instead of spawning cans (the older farm-style cow barn), it uses the normal RLRM rules - only lactating cows contribute.

> **Hof Bergmann v1.3:** the can-collecting cow buildings don't produce milk cans on the v1.3 configuration yet - a known limitation. The v1.4 configuration is where cow-pasture milk works.

---

## Known Limitations

### Pasture Bulls Are Not Cattle

Hof Bergmann adds a **BULL** animal type for decorative pasture bulls. These are **not the same** as the bull breeds in the cattle system (Holstein Bull, Angus Bull, etc.).

In the base game and in RLRM, cattle bulls are subtypes of the **COW** animal type. A Holstein Bull and a Holstein Cow are both "COW" internally - they share the same husbandry, the same breeding system, and the same lifecycle. This is what allows bulls and cows to breed with each other.

Hof Bergmann's pasture bull is a completely separate animal type called **BULL**. The game engine treats each animal type as isolated - animals of different types cannot interact, breed, or share husbandries. The pasture bull has its own husbandry building, its own slot system, and its own internal logic.

**Why it can't be "just fixed":** Merging HB's BULL type into the COW type would require rewriting the map's husbandry building assignments, pasture system, and animal slot management. This isn't a mod-side fix - it would need changes to the map itself. Alternatively, implementing cross-type breeding (letting a BULL-type animal breed with a COW-type animal) would be a fundamental new system in the game engine that doesn't exist.

**"Can't you just use the pasture bull models on cow-type bulls?"** This is a natural question. The base game doesn't include separate bull 3D models at all - RLRM's breeding bulls (Holstein Bull, Angus Bull, etc.) reuse the female cow models, so visually they look the same as cows. HB's pasture bulls have their own distinct bull visuals, which is exactly what you'd want on your breeding bulls.

Unfortunately, each animal type loads its own set of 3D models from the map's configuration - the COW type has one model pool, the BULL type has a completely separate one. To use HB's bull models on COW-type animals, you'd have to rebuild the map's entire animal model loading infrastructure from a script mod and apply it on top. This is extremely brittle: any map update can shift model indices, causing wrong or missing visuals.

The pasture bull still gets individual tracking, a name, and genetics - it just doesn't participate in the cattle breeding and reproduction system.

**No bull sperm collection under RLRM.** Hof Bergmann's bull stable produces BULLSPERM by modelling it as a milk output on the BULL subtype. In vanilla FS25 this works because the cluster-based milk pipeline lets the curve run on any subtype regardless of gender. RLRM replaces that pipeline with per-animal output that gates milk production on lactating female cows that have given birth in the last 10 months - none of which applies to the BULL animal type. The BULLSPERM collection trigger at the bull stable stays empty under RLRM. Loosening the gate broadly would let any male animal "produce milk" anywhere a map mod declares such an output, so this is documented as a known incompatibility rather than patched.

### Dogs Are Companion Animals

Hof Bergmann includes 8 dog breeds (4 Labrador variants, 4 Border Collie variants). In base FS25, dogs are companion animals with special behaviour.

RLRM tracks dogs as individuals with names and genetics, but does not add breeding or reproduction. Dogs remain companion animals that behave the same as in vanilla FS25.

### Bundled Animal Transport Pack

Hof Bergmann is distributed together with a separate mod, **FS25_lsfmAnimalTransportPack.zip** (the LSFM Animal Transport Pack). Because it arrives with the map, it is easy to assume it is part of Hof Bergmann itself - it is not, and the limitation below is a fault of that pack, not the map.

The transport pack's animal herding / driving feature does not work with RLRM. Driving animals opens the animal screen through the pack's custom object instead of a standard livestock trailer, and RLRM's rewritten animal screen does not recognise that call, so the action fails; there may be further errors later in the process. Everything else on the map works normally, and the rest of the transport pack is unaffected.

See [Mod Compatibility](reference-mod-compatibility.md#partial-compatibility) for the full compatibility list.

---

## Related Pages

- [Breeding Guide](guide-breeding.md) - How breeding works for all supported animals
- [Genetics Guide](guide-genetics.md) - How traits are inherited
- [FAQ: Can you add more breeds?](faq.md#can-you-add-more-breeds-or-animal-types) - Why new breeds aren't created from scratch
- [FAQ: Why don't HB bulls breed like cattle?](faq.md#why-dont-hof-bergmann-pasture-bulls-breed-like-cattle) - More detail on the BULL vs COW limitation
- [Mod Compatibility](reference-mod-compatibility.md) - Which mods conflict with or work alongside RLRM
