# Sheep & Goats Factsheet

Sheep and goats share a husbandry but have different production types. Sheep produce wool (only on days whose lowest temperature stays at 12C or above), while goats produce goat milk (requires lactation). Four sheep breeds offer different wool/price trade-offs, and goats are a distinct breed-locked type.

> **Note:** This documentation was generated with AI assistance and may contain inaccuracies. If you spot an error, please [open an issue](https://github.com/rittermod/FS25_RealisticLivestockRM/issues).

---

## Breeds at a Glance

### Sheep

| Breed | Target Weight (ewe / ram) | Wool Range (peak) | Sell Value |
|-------|--------------------------|-------------------|------------|
| **Black Welsh** (Black Welsh Mountain in game) | 42 / 57.5 kg | 24 - 166 | Lowest |
| **Landrace** (Landrace of Bentheim in game) | 45 / 60 kg | 21 - 149 | Below average |
| **Steinschaf** | 50 / 67.5 kg | 18 - 123 | Above average |
| **Swiss Mountain** (Swiss Black-Brown Mountain in game) | 80 / 105 kg | 14 - 96 | Highest |

*Black Welsh produce the most wool, but Swiss Mountain sell for double the price. Wool range shows the full span from poor to excellent genetics.*

*Food, water, straw and production figures are per in-game month, whatever your month length. The animal's info box shows them per day, so with 3 days per month it shows a third of these figures.*

### Goat

| Breed | Target Weight (doe / ram) | Goat Milk Range (peak, lactating) | Sell Value |
|-------|--------------------------|----------------------------------|------------|
| **Goat** (ram: Goat Ram in game) | 30 / 35 kg | 5 - 57 L/month | High |

*Rams are heavier than ewes/does.*

> **Breed-locking:** Ram Goats can only breed with Goats. Other rams can breed with any sheep breed but not with Goats.

---

## Wool Production (Sheep Only)

Both ewes and rams produce wool - identical output per breed. **Wool is only produced on days whose lowest temperature stays at 12C or above.** In winter, wool output drops to zero.

### Wool Output Range (units/month, warm weather)

| Breed | 6 mo | 18 mo (peak) |
|-------|------|--------------|
| **Black Welsh** | 5 - 35 | **24 - 166** |
| **Landrace** | 4 - 26 | **21 - 149** |
| **Steinschaf** | 3 - 21 | **18 - 123** |
| **Swiss Mountain** | 2 - 14 | **14 - 96** |

*Genetics cause large variation between individual animals. Most sheep produce somewhere in the middle of these ranges. (Sheep never lactate, so they cannot catch mastitis - it only affects lactating goats.)*

---

## Goat Milk Production

Goats produce milk **only while lactating** (10 months after giving birth). Goat milk is a separate product from cow milk (Goat Milk in game - requires compatible storage).

### Goat Milk Output Range (L/month, lactating)

| Age | Range |
|-----|-------|
| Early lactation | ramping up toward peak |
| 18+ mo (peak) | **5 - 57** |

*Goats only lactate after their first kidding (from about 14 months), so there is no milk before then. Output ramps up over the first months of each lactation to the peak shown. Genetics and lactation phase cause large variation between individual animals; non-lactating goats produce zero milk.*

---

## Sell Prices by Breed

Sheep and goat prices peak at 36 months and stay at that level for older animals.

### Typical Sell Prices ($)

| Breed | | Newborn | 36 mo (peak) |
|-------|---|---------|--------------|
| **Black Welsh** | Ewe | 35 | 520 |
| | Ram | 45 | 600 |
| **Landrace** | Ewe | 40 | 550 |
| | Ram | 50 | 675 |
| **Steinschaf** | Ewe | 80 | 900 |
| | Ram | 100 | 1,050 |
| **Swiss Mountain** | Ewe | 100 | 1,050 |
| | Ram | 120 | 1,200 |
| **Goat** | Doe | 100 | 1,000 |
| | Ram Goat | 150 | 1,500 |

*These are typical prices for an average, healthy animal. Actual prices vary widely - well-bred healthy animals sell for significantly more, poor-quality animals can sell for far less, and a sick animal cannot be sold at the dealer until it recovers.*

### What Affects Sell Price

| Factor | Effect |
|--------|--------|
| Quality genetics | Better genetics -> considerably higher price |
| Weight | Well-fed animals near target weight are worth more |
| Health | Healthy animals sell for significantly more |
| Lactating (goats only) | Small price bonus |
| Pregnant | Moderate price bonus |
| Castrated | Small price bonus |
| Diseases | A sick animal cannot be sold at the dealer until it recovers |

### Buy Prices

The dealer's price is the animal's own sale value plus a markup that depends on the [**Dealer Animal Quality**](reference-settings.md#dealer-ai) setting, plus a transport fee per animal. So it follows the same things as the sale value: age, genetics, health, weight and pregnancy. Buying into a trailer at the dealer has no transport fee.

---

## Food & Water by Breed

Genetics significantly affect how much each animal eats - some are naturally much more efficient than others. Lactating goats eat noticeably more, and the Food Scale setting also adjusts consumption. Food and water rise through a pregnancy, more with a bigger litter: considerably higher by the end with twins.

### Food Consumption Range (L/month)

| Breed | | Newborn | 18+ mo (adult) |
|-------|---|---------|-----------------|
| **Black Welsh** | Ewe | 1 - 5 | 22 - 154 |
| | Ram | 1 - 5 | 23 - 163 |
| **Landrace** | Ewe | 1 - 7 | 25 - 175 |
| | Ram | 1 - 7 | 28 - 193 |
| **Steinschaf** | Ewe | 2 - 12 | 28 - 193 |
| | Ram | 2 - 12 | 30 - 210 |
| **Swiss Mountain** | Ewe | 3 - 18 | 30 - 210 |
| | Ram | 3 - 18 | 33 - 228 |
| **Goat** | Doe | 1 - 9 | 13 - 88 |
| | Ram Goat | 1 - 9 | 14 - 95 |

*Black Welsh are the cheapest to feed. Swiss Mountain eat the most. Goats are very efficient. Ranges show the span from the most efficient to the hungriest animals.*

### Water Consumption (L/month, newborn -> adult)

| Breed | Female | Male |
|-------|--------|------|
| **Black Welsh** | 3 -> 54 | 3 -> 58 |
| **Landrace** | 3 -> 60 | 3 -> 70 |
| **Steinschaf** | 4 -> 70 | 4 -> 76 |
| **Swiss Mountain** | 5 -> 85 | 5 -> 89 |
| **Goat** | 2 -> 20 | 2 -> 23 |

*Goats drink very little water compared to sheep. Lactating goats drink considerably more water than usual, and water rises through a pregnancy as well.*

---

## Weights by Breed

| Breed | | Birth | Target | Maximum |
|-------|---|-------|--------|---------|
| **Black Welsh** | Ewe | 4.2 kg | 42 kg | 135 kg |
| | Ram | 4.6 kg | 57.5 kg | 150 kg |
| **Landrace** | Ewe | 4.4 kg | 45 kg | 135 kg |
| | Ram | 4.7 kg | 60 kg | 150 kg |
| **Steinschaf** | Ewe | 4.8 kg | 50 kg | 135 kg |
| | Ram | 5.3 kg | 67.5 kg | 150 kg |
| **Swiss Mountain** | Ewe | 5.8 kg | 80 kg | 135 kg |
| | Ram | 6.5 kg | 105 kg | 150 kg |
| **Goat** | Doe | 3.75 kg | 30 kg | 90 kg |
| | Ram Goat | 4.0 kg | 35 kg | 115 kg |

*Swiss Mountain sheep are nearly double the weight of Black Welsh. Goats are the lightest. Higher metabolism animals reach target weight faster but eat more. Metabolism also moves each animal's own target weight: high-metabolism animals settle noticeably above the figure shown, low-metabolism animals noticeably below it.*

---

## Reproduction

| Parameter | Sheep | Goat |
|-----------|-------|------|
| Female breeding age | 8+ months | 8+ months |
| Ram breeding age | 5+ months | 5+ months |
| Ram max breeding age | 72 months (6 years) | 72 months (6 years) |
| Female fertility ends | 120 months (10 years) | 120 months (10 years) |
| Gestation | 5 months | 5 months |
| Min health to breed | 75% | 75% |

*See the [Breeding Reference](reference-breeding.md) for a side-by-side table of breeding ages, gestation, and litter sizes across all species.*

> **Note:** Rams stop breeding at 72 months - earlier than the ewe's fertile period (120 months). Replace your rams regularly!

### Offspring per Birth

Sheep and goats usually produce twins - at every age, including first-time mothers. Litter size is mostly chance. Well below average fertility makes triplets less likely; above average adds nothing.

| Outcome | Likelihood |
|---------|------------|
| Twins | Most likely |
| Triplets | Uncommon |
| Single | Uncommon |

*Litter size does not depend on age. Goats breed from the same age as sheep (8 months) and follow the same twin-heavy pattern. Age does not change a female's chance of conceiving - fertility genetics do. That chance holds until her end age of 120 months, then stops outright. Only animals with poor fertility genetics slow down in their last stretch.*

---

## Lifespan & Death

| Event | Age |
|-------|-----|
| Ram stops breeding | 72 months (6 years) |
| Female stops breeding | 120 months (10 years) |
| Old age deaths begin | 120 months (10 years) |
| Maximum lifespan (rarely reached) | ~144 months (12 years) |

*Most animals die of old age well before the maximum lifespan; only the best health genetics get close. Sheep have the shortest lifespan among large livestock. Old age deaths can begin as soon as breeding ends. Death can be toggled off in settings.*

---

## Diseases

| Disease | Spread | Fatal? | Treatment | Impact |
|---------|--------|--------|-----------|--------|
| **Mastitis** | Slowly | Rarely | 1 month, $200 | Stops goat milk (only lactating goats can catch it) |
| **Foot and Mouth** | Rapidly | Low to moderate | 1 month, $250 | Major price loss; slightly reduces wool/milk while sick |
| **Pulpy Kidney** | None | High - worst in lambs and kids | 1 month, $150 (cures about half the time) | Major price loss; considerably less wool/milk while sick |
| **Footrot** | Slowly | Never | 1 month, $100 (cures about 9 times in 10) | Major price loss; considerably less wool/milk while sick, for at least 6 months untreated |

*Sheep never lactate, so mastitis only affects lactating goats, stopping their milk. Pulpy kidney never passes between animals, and lambs and kids up to 12 months old catch it most often. The Fatal column holds while **Animal Death** is on. A sick animal cannot be sold at the dealer; the price loss shown is its value while sick, which sets what culling pays. See the [Disease Guide](guide-diseases.md) for detailed prevention and treatment.*

Sheep and goats can be vaccinated against pulpy kidney, and the lambs and kids of a protected ewe or doe are born protected for 2 months. They can also be vaccinated against footrot (6 months, $10 a dose), which passes nothing to newborns. Female goats can also be vaccinated against mastitis - see [Vaccination](guide-diseases.md#vaccination).

---

## Tips

1. **Wool vs price trade-off:** Black Welsh produce far more wool than Swiss Mountain, but Swiss Mountain sell for double. Choose based on whether you want wool income or sell income.

2. **Twins are the norm.** Sheep and goats produce twins more often than singles, at any age. Budget pen space for 2 lambs per ewe per cycle.

3. **Goats are niche.** Goat Milk requires specific storage and processing. Make sure you have compatible facilities before investing.

4. **Seasonal wool.** Wool is only produced on days whose lowest temperature stays at 12C or above, so a warm day after a cold night gives none. In cold climates with long winters, wool income will be seasonal. Plan accordingly.

5. **Short lifespan.** Sheep can start dying of old age at 10 years - right when they stop breeding. Sell ageing sheep before they die of old age to recover value.
