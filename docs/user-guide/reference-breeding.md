# Breeding Reference

Quick lookup table for every breed's breeding window, gestation length, and litter sizes. Use this when planning herds: when you can buy juveniles for breeding, when males retire, how long pregnancy takes, and how many offspring to budget pen space for.

For per-species context (food, prices, fertility-by-age curves, complications) see the species factsheets and the [Breeding Guide](guide-breeding.md).

> **Note:** This documentation was generated with AI assistance and may contain inaccuracies. If you spot an error, please [open an issue](https://github.com/rittermod/FS25_RealisticLivestockRM/issues).

---

## Reference Table

Each breed has two rows - one for females, one for males. Gestation and litter size are female-only stats, so the male row leaves those columns blank.

| Species | Breed | Sex | Breeds from | Breeds until¹ | Gestation | Peak litter (max)² |
|---------|-------|-----|-------------|---------------|-----------|---------------------|
| **Cattle** | Swiss Brown | Female | 12 mo | 132 mo (11 yr) | 10 mo | 1 (max 3) |
|            |             | Male   | 12 mo | 132 mo (11 yr) | -     | -          |
| **Cattle** | Holstein    | Female | 12 mo | 132 mo (11 yr) | 10 mo | 1 (max 3) |
|            |             | Male   | 12 mo | 132 mo (11 yr) | -     | -          |
| **Cattle** | Angus       | Female | 12 mo | 132 mo (11 yr) | 10 mo | 1 (max 3) |
|            |             | Male   | 12 mo | 132 mo (11 yr) | -     | -          |
| **Cattle** | Limousin    | Female | 12 mo | 132 mo (11 yr) | 10 mo | 1 (max 3) |
|            |             | Male   | 12 mo | 132 mo (11 yr) | -     | -          |
| **Cattle** | Hereford    | Female | 12 mo | 132 mo (11 yr) | 10 mo | 1 (max 3) |
|            |             | Male   | 12 mo | 132 mo (11 yr) | -     | -          |
| **Cattle** | Highland *(DLC)* | Female | 12 mo | 132 mo (11 yr) | 10 mo | 1 (max 3) |
|            |             | Male   | 12 mo | 132 mo (11 yr) | -     | -          |
| **Cattle** | Brahman *(DLC)* | Female | 12 mo | 132 mo (11 yr) | 10 mo | 1 (max 3) |
|            |             | Male   | 12 mo | 132 mo (11 yr) | -     | -          |
| **Cattle** | Water Buffalo³ | Female | 12 mo | 132 mo (11 yr) | 10 mo | 1 (max 3) |
|            |             | Male   | 12 mo | 132 mo (11 yr) | -     | -          |
| **Pigs**   | Berkshire   | Female | 6 mo  | 96 mo (8 yr)   | 4 mo  | 12 (max 16) |
|            |             | Male   | 8 mo  | 48 mo (4 yr)   | -     | -          |
| **Pigs**   | Landrace    | Female | 6 mo  | 96 mo (8 yr)   | 4 mo  | 12 (max 16) |
|            |             | Male   | 8 mo  | 48 mo (4 yr)   | -     | -          |
| **Pigs**   | Black Pied  | Female | 6 mo  | 96 mo (8 yr)   | 4 mo  | 12 (max 16) |
|            |             | Male   | 8 mo  | 48 mo (4 yr)   | -     | -          |
| **Sheep**  | Black Welsh | Female | 8 mo  | 120 mo (10 yr) | 5 mo  | 2 (max 3) |
|            |             | Male   | 5 mo  | 72 mo (6 yr)   | -     | -          |
| **Sheep**  | Landrace    | Female | 8 mo  | 120 mo (10 yr) | 5 mo  | 2 (max 3) |
|            |             | Male   | 5 mo  | 72 mo (6 yr)   | -     | -          |
| **Sheep**  | Steinschaf  | Female | 8 mo  | 120 mo (10 yr) | 5 mo  | 2 (max 3) |
|            |             | Male   | 5 mo  | 72 mo (6 yr)   | -     | -          |
| **Sheep**  | Swiss Mountain | Female | 8 mo | 120 mo (10 yr) | 5 mo | 2 (max 3) |
|            |             | Male   | 5 mo  | 72 mo (6 yr)   | -     | -          |
| **Goats**  | Goat³       | Female (Doe)   | 8 mo  | 120 mo (10 yr) | 5 mo  | 2 (max 3) |
|            |             | Male (Ram Goat) | 5 mo  | 72 mo (6 yr)   | -     | -          |
| **Horses** | All 8 colour variants | Female (Mare)    | 22 mo | 264 mo (22 yr) | 11 mo | 1 (max 3) |
|            |             | Male (Stallion)  | 24 mo | 300 mo (25 yr) | -     | -          |
| **Chickens** | Chicken   | Female (Hen)     | 6 mo  | 60 mo (5 yr)   | 2 mo  | 5 (max 12) |
|              |           | Male (Rooster)   | 6 mo  | 72 mo (6 yr)   | -     | -          |

¹ The male upper limit is scaled by individual fertility genetics. A high-fertility bull may breed past 132 months; a low-fertility one retires earlier. Roosters are the exception: their 72-month cap is absolute and not scaled by genetics. The female limit is the hard end of the fertility curve.

² "Peak" is the typical litter size when a mother conceives. "Max" is the upper bound seen with high-fertility mothers. Litter size is driven by the mother's fertility genetics, not her age - age only affects whether she conceives at all (her fertility curve tapers to zero at the "Breeds until" age).

³ Breed-locked: Water Buffalo only breed with Water Buffalo; Goats only breed with Ram Goats. All other breeds within a species can cross-breed (Angus bull x Holstein cow, Berkshire boar x Landrace sow, etc.). See the [Breeding Guide](guide-breeding.md#breed-restrictions).

> **Health gate:** Every species requires the female to be at **75%+ health** to conceive. Below 75%, conception fails entirely. A stillborn newborn can occasionally cost the mother her life too, more so with poor health genetics. See the [Breeding Guide](guide-breeding.md#pregnancy-complications) for full mechanics.

---

## At a Glance

A few patterns worth highlighting:

- **Pigs have the shortest male window.** Boars retire at 4 years while sows breed until 8 - replace breeding boars early.
- **Sheep and goats also asymmetric.** Rams retire at 6 years, ewes/does breed until 10.
- **Does and ewes now match.** Goats breed from 8 months, the same as sheep - goats are no longer the late starter.
- **Horses are the slowest cycle.** 11-month gestation and single foals make horse breeding a long-term investment.
- **Pigs are the fastest.** 4-month gestation plus 12-piglet litters means a healthy sow produces 30+ piglets per year at prime age.
- **Roosters retire at 6 years.** A rooster sires until 72 months, then stops - unlike other males, the cap is fixed, not genetics-scaled.

---

## See Also

- [Breeding Guide](guide-breeding.md) - fertility curves, lactation, complications, artificial insemination
- [Cattle Factsheet](factsheet-cattle.md) - per-breed prices, milk, food, weights
- [Pigs Factsheet](factsheet-pigs.md) - per-breed prices, food, weights
- [Sheep & Goats Factsheet](factsheet-sheep.md) - per-breed prices, wool/milk, food, weights
- [Horses Factsheet](factsheet-horses.md) - sell-price factors, food, weights
- [Chickens Factsheet](factsheet-chickens.md) - egg production, food, weights
- [Settings Reference](reference-settings.md) - every configurable mod option
