# Realistic Livestock RM - Overview

Realistic Livestock RM transforms the animal system in Farming Simulator 25. Instead of anonymous clusters, every animal is a unique individual with its own genetics, health history, and lifecycle.

> **Note:** This documentation was generated with AI assistance and may contain inaccuracies. If you spot an error, please [open an issue](https://github.com/rittermod/FS25_RealisticLivestockRM/issues).

---

## What Changes

### Every Animal Is Unique

Each animal you buy or breed is tracked individually. They have a name tag, a birthday, and five genetic traits that make them different from every other animal in your herd. Two Holstein cows bought on the same day will produce different amounts of milk, eat different amounts of food, and sell for different prices.

### Genetics

Every animal is born with five genetic traits rated from Extremely Low to Extremely High:

- **Health** - Disease resistance and longevity
- **Fertility** - Breeding success rate
- **Productivity** - Milk, egg, and wool output (cows, sheep, goats, chickens only)
- **Quality** - Sell price and meat value
- **Metabolism** - Food consumption and weight gain

Offspring inherit traits from their parents, so selective breeding pays off over time. Most animals you encounter will be average, but occasionally you'll find an exceptional one - or a dud.

See the [Genetics Guide](guide-genetics.md) for the full rating scale and breeding tips.

### Realistic Breeding

Reproduction requires a male and female of the same species in the same pen. Each species has different breeding ages, gestation periods, and litter sizes:

| Animal | Gestation | Typical Offspring |
|--------|-----------|-------------------|
| Cattle | 10 months | 1 calf (twins uncommon) |
| Pigs | 4 months | ~12 piglets (up to 16) |
| Sheep / Goats | 5 months | 2 lambs (twins usual) |
| Horses | 11 months | 1 foal |
| Chickens | 2 months | ~5 chicks (up to 12) |

Males and females have different fertility windows - boars retire from breeding at just 4 years while sows can breed until 8 years. Cows lactate for 10 months after giving birth, during which they produce milk but need more food and water.

**Artificial Insemination** is available through the livestock menu if you don't want to keep a male.

See the [Breeding Guide](guide-breeding.md) for full details per species.

### Animal Management

Individual animals can be monitored, marked, and castrated:

- **Monitoring** - Place monitors on animals to track their stats over time. View active monitors in the livestock menu.
- **Marking** - Mark animals for visual identification in your herd
- **Castration** - Castrate males for a small sell price bonus. Castrated animals grow faster but cannot breed.

### Diseases

Five diseases can affect your animals:

| Disease | Affects | Treatable? | Key Impact |
|---------|---------|------------|------------|
| Mastitis | Cows, Goats | Yes | Stops milk production (lactating animals only) |
| CVM | Cattle (genetic) | No | Carrier cows produce extra milk, but calves may die |
| Foot & Mouth | Cows, Sheep, Pigs | Yes (slow) | Major milk and price reduction |
| PED | Pigs | Yes | Devastating to newborn piglets |
| Avian Influenza | Chickens | No | Stops all egg production |

Diseases can spread between animals in the same pen. Some diseases grant immunity after recovery.

See the [Disease Guide](guide-diseases.md) for prevention and treatment strategies.

### Death

Animals can die from three causes:

- **Old age** - Each species has a natural lifespan (chickens ~5-8 years, horses ~25-30 years)
- **Low health** - Unhealthy animals face increasing death risk
- **Accidents** - Random events affected by weather conditions

Death mechanics can be fully disabled or adjusted in the mod settings.

### Configurable Settings

Almost everything can be tuned to your preference:

- Toggle death and diseases on/off
- Scale food consumption up or down
- Adjust accident and disease probability
- Control dealer stock size
- Choose which breeds and age groups the animal dealer offers at all
- Set how good - and how expensive - the dealer's animals are (Budget / Standard / Premium)
- Customise ear tag colours
- Display genetics values in animal names (short or detailed format)
- Export animal data to CSV
- Choose between individual event messages or daily summaries

All of these live in the RL Menu's Settings tab - the in-game menu's Game Settings page has an **Open Settings** button (under "Realistic Livestock") that takes you straight there. See the [Settings Reference](reference-settings.md) for all options.

### Livestock Menu

Open the **RL Menu** with **Right Shift + O** in-game - or, from the ESC menu's **Animals** page, select a pen and press **R** ("Manage Animals"). It has eight tabs:

- **Buy** - Purchase animals from the dealer with full genetics preview
- **Sell** - Sell animals back to the dealer
- **Move** - Transfer animals between your husbandries
- **Manage** - View detailed stats, genetics, health, and production for each animal
- **Insemination** - Browse and buy stored semen for artificial breeding without keeping males
- **Message Log** - Track births, deaths, diseases, and other events
- **Herdsman** - Automate daily herd chores with rules: sell, buy, move, castrate, name, or inseminate the animals a saved filter picks, in the pens you choose. See the [Herdsman guide](guide-herdsman.md).
- **Settings** - Adjust every RLRM option: death and disease toggles, food scaling, dealer stock size, how good the dealer's animals are, which breeds and age groups the dealer offers, ear tag colours, genetics display, CSV export, and more. This tab also hosts the **saved filter** editor.

**Saved filters** let you narrow the Buy, Sell, Move, and Manage lists to just the animals you care about - and they are how the Herdsman targets animals. Press **F** on any of those screens to cycle them. See the [Saved Filters guide](guide-saved-filters.md).

### Controls

| Key | Action | Where |
|-----|--------|-------|
| **Right Shift + O** | Open RL Menu | In-game |
| **R** | Open Manage Animals | Animal menu |
| **A** | Select / deselect | Buy and sell dialogs |
| **Shift + T** | Change visual animals amount (how many are shown in 3D) | In-game |
| **X** | Mark animal | Animal detail view |
| **M** | Toggle monitor | Animal detail view |
| **I** | Insemination | Animal detail view (females only) |
| **C** | Castrate | Animal detail view (males only) |
| **D** | Disease treatment | Animal detail view |
| **N** | Rename animal | Animal detail view |
| **F** | Cycle saved filter | Animal lists |

*All keybindings can be remapped in the game's input settings.*

### Map & Mod Support

RLRM works on virtually any map out of the box - it does not need to be on a list. The maps below are special only because they add their own custom animal types or breeds; for those, the mod includes built-in support and auto-detects the installed map version so the custom animals also get full breeding and reproduction. On any other map, the standard animals just work.

- **[Hof Bergmann](map-hof-bergmann.md)** - Ducks, geese, cats, rabbits, alpacas, and quail fully supported with breeding, genetics, and reproduction. See the [dedicated page](map-hof-bergmann.md) for supported versions and known limitations (pasture bulls, dogs).
- **[Witcombe](map-witcombe.md)** - UK breeds (Jersey, Gloucestershire Old Spot, Texel, Suffolk, Blue Faced Leicester) plus rabbit keeping, fully supported with breeding, genetics, and reproduction. See the [dedicated page](map-witcombe.md) for supported versions and the Hereford heritage profile.
- **[Le Mechet](map-le-mechet.md)** - French breeds (Charolaise, Montbeliarde, Simmental, Vosgienne) fully supported with breeding, genetics, and reproduction, using the map's native 3D models. See the [dedicated page](map-le-mechet.md) for supported versions and caveats.

If a map updates to a version that hasn't been tested yet, you'll see a warning dialog when the game starts. The dialog includes a link to report any problems.

- **Extended Production Point (EPP)** - Basic support for moving animals to EPP butchers

*Looking for more breeds or animal types? See the [FAQ](faq.md#can-you-add-more-breeds-or-animal-types) for what's possible.*

---

## Species Factsheets

Each species has a detailed factsheet with breed comparisons, production ranges, and pricing:

- [Cattle Factsheet](factsheet-cattle.md) - 7 breeds from dairy Holsteins to beef Angus
- [Pigs Factsheet](factsheet-pigs.md) - 3 breeds with massive litter sizes
- [Sheep & Goats Factsheet](factsheet-sheep.md) - 4 sheep breeds + goats
- [Horses Factsheet](factsheet-horses.md) - 8 colour variants
- [Chickens Factsheet](factsheet-chickens.md) - Hens and roosters

## Guides

- [Genetics Guide](guide-genetics.md) - Trait ratings, breeding strategy, the CVM dilemma
- [Disease Guide](guide-diseases.md) - Prevention, treatment, and immunity
- [Breeding Guide](guide-breeding.md) - Fertility windows, offspring tables, lactation
- [Saved Filters](guide-saved-filters.md) - Build reusable animal filters and use them in-game
- [Herdsman Automation](guide-herdsman.md) - Automate selling, buying, moving, and more with daily rules
- [Hof Bergmann Map Support](map-hof-bergmann.md) - Exotic animals, supported versions, known limitations
- [Witcombe Map Support](map-witcombe.md) - UK breeds, supported versions, and the Hereford heritage profile
- [Le Mechet Map Support](map-le-mechet.md) - French breeds, supported versions, and caveats
- [Animal Packs](guide-animal-packs.md) - Installing and using third-party animal packs
- [Breeding Reference](reference-breeding.md) - Per-breed breeding ages, gestation, and litter sizes
- [Settings Reference](reference-settings.md) - Every configurable option explained
- [Mod Compatibility](reference-mod-compatibility.md) - Blocking conflicts and known-working integrations
- [FAQ](faq.md) - Common questions about genetics inheritance, breeding, and more
