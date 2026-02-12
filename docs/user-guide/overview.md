# Realistic Livestock RM — Overview

Realistic Livestock RM transforms the animal system in Farming Simulator 25. Instead of anonymous clusters, every animal is a unique individual with its own genetics, health history, and lifecycle.

> **Note:** This documentation was generated with AI assistance and may contain inaccuracies. If you spot an error, please [open an issue](https://github.com/rittermod/FS25_RealisticLivestockRM/issues).

---

## What Changes

### Every Animal Is Unique

Each animal you buy or breed is tracked individually. They have a name tag, a birthday, and five genetic traits that make them different from every other animal in your herd. Two Holstein cows bought on the same day will produce different amounts of milk, eat different amounts of food, and sell for different prices.

### Genetics

Every animal is born with five genetic traits rated from Extremely Low to Extremely High:

- **Health** — Disease resistance and longevity
- **Fertility** — Breeding success rate
- **Productivity** — Milk, egg, and wool output (cows, sheep, chickens only)
- **Quality** — Sell price and meat value
- **Metabolism** — Food consumption and weight gain

Offspring inherit traits from their parents, so selective breeding pays off over time. Most animals you encounter will be average, but occasionally you'll find an exceptional one — or a dud.

See the [Genetics Guide](guide-genetics.md) for the full rating scale and breeding tips.

### Realistic Breeding

Reproduction requires a male and female of the same species in the same pen. Each species has different breeding ages, gestation periods, and litter sizes:

| Animal | Gestation | Typical Offspring |
|--------|-----------|-------------------|
| Cattle | 10 months | 1 calf (twins rare) |
| Pigs | 4 months | 11-13 piglets |
| Sheep / Goats | 5 months | 1-2 lambs |
| Horses | 11 months | 1 foal |
| Chickens | 2 months | 1-12 chicks |

Males and females have different fertility windows — boars retire from breeding at just 4 years while sows can breed until 8 years. Cows lactate for 10 months after giving birth, during which they produce milk but need more food and water.

**Artificial Insemination** is available through the livestock menu if you don't want to keep a male.

See the [Breeding Guide](guide-breeding.md) for full details per species.

### Diseases

Five diseases can affect your animals:

| Disease | Affects | Treatable? | Key Impact |
|---------|---------|------------|------------|
| Mastitis | Cows, Sheep, Goats | Yes | Stops milk and wool production |
| CVM | Cattle (genetic) | No | Carrier cows produce extra milk, but calves may die |
| Foot & Mouth | Cows, Sheep, Pigs | Yes (slow) | Major milk and price reduction |
| PED | Pigs | Yes | Devastating to newborn piglets |
| Avian Influenza | Chickens | No | Stops all egg production |

Diseases can spread between animals in the same pen. Some diseases grant immunity after recovery.

See the [Disease Guide](guide-diseases.md) for prevention and treatment strategies.

### Death

Animals can die from three causes:

- **Old age** — Each species has a natural lifespan (chickens ~5-8 years, horses ~25-30 years)
- **Low health** — Unhealthy animals face increasing death risk
- **Accidents** — Random events affected by weather conditions

Death mechanics can be fully disabled or adjusted in the mod settings.

### Configurable Settings

Almost everything can be tuned to your preference:

- Toggle death and diseases on/off
- Scale food consumption up or down
- Adjust accident and disease probability
- Control dealer stock size
- Customise ear tag colours
- Export animal data to CSV

See the [Settings Reference](reference-settings.md) for all options.

### Livestock Menu

The mod adds a comprehensive livestock menu with several tabs:

- **Animal overview** — Browse individual animals with their stats, genetics, and health
- **Herdsman** — Set up automation rules for your herds
- **Artificial insemination** — Breed without keeping males
- **Message log** — Track births, deaths, diseases, and other events
- **CSV export** — Export detailed data for analysis

---

## Species Factsheets

Each species has a detailed factsheet with breed comparisons, production ranges, and pricing:

- [Cattle Factsheet](factsheet-cattle.md) — 7 breeds from dairy Holsteins to beef Angus
- [Pigs Factsheet](factsheet-pigs.md) — 3 breeds with massive litter sizes
- [Sheep & Goats Factsheet](factsheet-sheep.md) — 4 sheep breeds + goats
- [Horses Factsheet](factsheet-horses.md) — 8 colour variants
- [Chickens Factsheet](factsheet-chickens.md) — Hens and roosters

## Guides

- [Genetics Guide](guide-genetics.md) — Trait ratings, breeding strategy, the CVM dilemma
- [Disease Guide](guide-diseases.md) — Prevention, treatment, and immunity
- [Breeding Guide](guide-breeding.md) — Fertility windows, offspring tables, lactation
- [Settings Reference](reference-settings.md) — Every configurable option explained
