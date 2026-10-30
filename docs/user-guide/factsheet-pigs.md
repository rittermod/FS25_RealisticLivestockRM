# Pigs Factsheet

Pigs are the most prolific breeders in Realistic Livestock RM, with litters of up to 16 piglets. They produce no special outputs (just manure), so their value comes entirely from selling offspring. The three breeds differ significantly in price - Berkshire commands a premium while Black Pied is the budget option.

> **Note:** This documentation was generated with AI assistance and may contain inaccuracies. If you spot an error, please [open an issue](https://github.com/rittermod/FS25_RealisticLivestockRM/issues).

---

## Breeds at a Glance

| Breed | Type | Target Weight (sow / boar) | Sell Value | Character |
|-------|------|---------------------------|------------|-----------|
| **Berkshire** | Premium | 140 / 180 kg | Highest | Most valuable per head |
| **Landrace** (German Landrace in game) | Standard | 165 / 205 kg | Moderate | Balanced mid-range |
| **Black Pied** (Bentheim Black Pied in game) | Economy | 180 / 250 kg | Lowest | Cheapest, heaviest boars |

*Boars are heavier than sows and sell for more. Berkshire pigs eat the most but command the highest prices.*

---

## Output

Pigs produce only manure and liquid manure - no milk, wool, or eggs. Their value is entirely in selling the animals.

| Breed | Manure (adult, L/month) | Liquid Manure (adult, L/month) |
|-------|-------------------------|--------------------------------|
| **Berkshire** | 50 / 55 | 91 / 95 |
| **Landrace** | 45 / 48 | 85 / 88 |
| **Black Pied** | 40 / 44 | 79 / 83 |

*Values shown as sow / boar.*

*Food, water, straw and production figures are per in-game month, whatever your month length. The animal's info box shows them per day, so with 3 days per month it shows a third of these figures.*

---

## Sell Prices by Breed

Pig prices peak at 24 months and stay at that level for older animals (unlike cattle which decline).

### Typical Sell Prices ($)

| Breed | | Newborn | 6 mo | 24 mo (peak) |
|-------|---|---------|------|--------------|
| **Berkshire** | Sow | 28 | 356 | 1,600 |
| | Boar | 38 | 525 | 1,850 |
| **Landrace** | Sow | 25 | 316 | 1,400 |
| | Boar | 31 | 475 | 1,650 |
| **Black Pied** | Sow | 22 | 296 | 1,200 |
| | Boar | 28 | 450 | 1,500 |

*These are typical prices for an average, healthy animal. Actual prices vary widely - well-bred healthy animals sell for significantly more, poor-quality animals can sell for far less, and a sick animal cannot be sold at the dealer until it recovers.*

### What Affects Sell Price

| Factor | Effect |
|--------|--------|
| Quality genetics | Better genetics -> considerably higher price |
| Weight | Well-fed animals near target weight are worth more |
| Health | Healthy animals sell for significantly more |
| Pregnant | Moderate price bonus |
| Castrated | Small price bonus |
| Diseases | A sick animal cannot be sold at the dealer until it recovers |

### Buy Prices

The dealer's price is the animal's own sale value plus a markup that depends on the [**Dealer Animal Quality**](reference-settings.md#dealer-ai) setting, plus a transport fee per animal. So it follows the same things as the sale value: age, genetics, health, weight and pregnancy. Buying into a trailer at the dealer has no transport fee.

The transport fee grows with age, from $40 for a newborn to $150 for a sow or $250 for a boar at 12 months and older. It also comes off the price when you sell.

---

## Food & Water by Breed

Genetics significantly affect how much each animal eats - some are naturally much more efficient than others. The Food Scale setting also adjusts consumption.

### Food Consumption Range (L/month)

| Breed | | Newborn | 24 mo (adult) |
|-------|---|---------|---------------|
| **Berkshire** | Sow | 5-32 | 30-210 |
| | Boar | 5-35 | 33-228 |
| **Landrace** | Sow | 4-26 | 25-175 |
| | Boar | 4-26 | 28-193 |
| **Black Pied** | Sow | 3-21 | 23-161 |
| | Boar | 4-26 | 24-168 |

*Berkshire pigs eat the most. Black Pied are the most efficient to feed. Ranges show the span from the most efficient to the hungriest animals. Most animals eat near the middle of these ranges.*

### Water Consumption (L/month, newborn -> adult)

| Breed | Sow | Boar |
|-------|-----|------|
| **Berkshire** | 10 -> 80 | 13 -> 85 |
| **Landrace** | 8 -> 75 | 8 -> 80 |
| **Black Pied** | 6 -> 68 | 8 -> 72 |

*A pregnant sow eats and drinks up to about twice as much as usual for most of her pregnancy.*

### Straw Consumption (L/month, newborn -> adult)

| Breed | Sow | Boar |
|-------|-----|------|
| **Berkshire** | 5 -> 20 | 5 -> 20 |
| **Landrace** | 5 -> 20 | 5 -> 20 |
| **Black Pied** | 5 -> 20 | 5 -> 20 |

*Straw is not affected by genetics or pregnancy.*

---

## Weights by Breed

| Breed | | Birth | Target | Maximum |
|-------|---|-------|--------|---------|
| **Berkshire** | Sow | 1.6 kg | 140 kg | 1,050 kg |
| | Boar | 1.7 kg | 180 kg | 1,200 kg |
| **Landrace** | Sow | 1.36 kg | 165 kg | 1,050 kg |
| | Boar | 1.4 kg | 205 kg | 1,200 kg |
| **Black Pied** | Sow | 1.65 kg | 180 kg | 1,050 kg |
| | Boar | 1.75 kg | 250 kg | 1,200 kg |

*Black Pied boars have the highest target weight at 250 kg. Higher metabolism animals reach target weight faster but eat more. Metabolism also moves each animal's own target weight: high-metabolism animals settle noticeably above the figure shown, low-metabolism animals noticeably below it. Castrated pigs gain weight faster than intact males.*

---

## Reproduction

| Parameter | Value |
|-----------|-------|
| Sow breeding age | 6+ months |
| Boar breeding age | 8+ months |
| Boar max breeding age | 48 months (4 years) |
| Sow fertility ends | 96 months (8 years) |
| Gestation | 4 months |
| Min health to breed | 75% |

*See the [Breeding Reference](reference-breeding.md) for a side-by-side table of breeding ages, gestation, and litter sizes across all species.*

> **Key insight:** Boars retire from breeding at just 4 years while sows can breed until 8 years. Plan your boar replacements early!

### Litter Sizes

Pig litters are the largest of any animal - typically around 12 piglets, and very rarely up to 16. Litter size is mostly chance. Well below average fertility rules out the largest litters; above average adds nothing.

| Outcome | Likelihood |
|---------|------------|
| ~12 piglets (typical) | Most likely |
| Smaller litter | Uncommon |
| 13-15 piglets | Rare |
| 16 piglets | Very rare |

*Age does not change a sow's chance of conceiving - fertility genetics do. That chance holds until her end age of 96 months, then stops outright. Litter size does not depend on age either. A sow must be at 75% health or above to conceive.*

---

## Lifespan & Death

| Event | Age |
|-------|-----|
| Boar stops breeding | 48 months (4 years) |
| Sow stops breeding | 96 months (8 years) |
| Old age deaths begin | 180 months (15 years) |
| Maximum lifespan (rarely reached) | ~240 months (20 years) |

*Most animals die of old age well before this; only the best health genetics get close. Death can be toggled off in settings. Accidents can happen at any age (affected by weather). Animals in poor health can also die at any age, the very young most easily.*

---

## Diseases

| Disease | Spread | Fatal? | Treatment | Impact |
|---------|--------|--------|-----------|--------|
| **Foot and Mouth** | Rapidly | Low to moderate | 1 month, $250 | Major price loss, slower growth |
| **PED** | Moderately | Moderate - worst in young piglets | 1 month, $150 | Severe diarrhoea (liquid manure drastically increased, solid manure severely reduced) |

*The Fatal column holds while **Animal Death** is on. A sick animal cannot be sold at the dealer; the price loss shown is its value while sick, which sets what culling pays.*

> **PED warning:** Porcine Epidemic Diarrhoea hits young piglets hardest - newborn piglets in their first month catch it most often, and young piglets are the most at risk from it. Older pigs rarely catch it on their own, but any pig can catch it from a sick pen mate - treat quickly. See the [Disease Guide](guide-diseases.md).

Pigs can be vaccinated against PED, and the piglets of a protected sow are born protected for their first month - see [Vaccination](guide-diseases.md#vaccination).

---

## Tips

1. **Breeding is the business model.** With litters of around 12 piglets (up to 16) and a 4-month gestation plus recovery time, a healthy sow can produce a litter roughly every 7 months. Sell the excess for profit.

2. **Replace boars early.** Boars stop breeding at just 4 years - half the sow's fertile period. Buy young boars regularly or use artificial insemination.

3. **Berkshire for profit, Black Pied for volume.** Berkshire piglets sell for noticeably more but eat more. Black Pied are cheaper to maintain for large-scale operations.

4. **Watch for PED.** Newborn piglets catch it most often and young piglets are the most at risk, so treat every case at once ($150). Vaccinate your sows ($15) so the protection still runs when they farrow: their piglets are then born protected for that first month. If it keeps recurring, a lower **Diseases** setting can protect your investment.

5. **Pen capacity matters.** If a pen is full when piglets are born, the excess are automatically sold. Make sure you have room for a full litter of around 12 piglets.
