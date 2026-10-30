# Alpacas Factsheet

The alpacas on this page need the **Beans & Alpacas Expansion**. They produce fleece, which is sheared off once a coat has grown, and each alpaca has a **happiness** level that moves its price, its fleece growth and its health. All four coat colours have identical stats, so colour is purely cosmetic.

> **Note:** This documentation was generated with AI assistance and may contain inaccuracies. If you spot an error, please [open an issue](https://github.com/rittermod/FS25_RealisticLivestockRM/issues).

---

## Breeds at a Glance

| Coat Colour | Target Weight (female / male) | Fleece Range (full coat) | Typical Sell Price (peak) |
|-------------|-------------------------------|--------------------------|---------------------------|
| **White, Brown, Grey, Fawn** | 60 / 65 kg | 125 - 875 L | 5,350 - 6,700 |

*Fleece range shows the full span from poor to excellent genetics.*

The expansion has no male alpacas, so Realistic Livestock RM adds a male for each colour: a female needs a male in the pen to get pregnant (an AI straw works too). Males count toward the alpaca shed's limit of 16 animals, so leave room for one.

Hof Bergmann has its own alpacas, which differ from the ones on this page - see [Hof Bergmann](map-hof-bergmann.md).

---

## Fleece and Happiness

Every alpaca, male or female, carries **happiness** and **fleece**, shown on its **Manage** tab, its HUD box and the dealer card.

- **Happiness** drops about 10% a month, whatever your month length, and it only comes back when the alpaca is led. A happier alpaca sells for noticeably more and grows its fleece faster.
- **Health** depends on happiness too from 14 months, when an alpaca can be led. An adult that is never led needs hay to stay healthy, because grass alone is not enough. A younger alpaca's health depends on its food alone.
- **Fleece** grows every day from birth, whatever your month length: about 10% a month when fully happy and half that with no happiness, so a full coat takes about 10 to 20 months. From 40% fleece an adult alpaca (14 months and older) shows its woolly coat and can be sheared; below that it looks sheared.

### Fleece per Shearing (L)

| Fleece when sheared | Fleece collected |
|---------------------|------------------|
| 40% | 50 - 350 |
| 100% (full coat) | **125 - 875** |

*The Fleece production genetics cause large variation between individual animals. An average alpaca gives 500 L from a full coat. Shearing takes the coat back to 0%.*

### Leading and Shearing by Hand

Buy an **Alpaca Leash** and a **Shearing Tool** from the shop. From 14 months an alpaca can be led out of the shed on the leash and back again. About 5 minutes of walking takes happiness from empty to full.

A woolly alpaca led into the alpaca shed can be sheared by hand, and its fleece fills the shed's fleece pallet.

### The Animal Worker

The game's animal worker can do both jobs for a fee. Hire it on the Animals page with **Manage Animal Workers**.

| Task | When | What it does |
|------|------|--------------|
| **Leading** | Every day | Takes every alpaca from 14 months to full happiness |
| **Shearing** | Once a year, on the first day of late spring | Shears every woolly alpaca in the pen |

A message the day before shearing reminds you to have your alpacas inside the shed. The fleece fills a pallet only in a shed with a fleece pallet (the expansion's alpaca shed); in any other pen the alpacas are still sheared, but the fleece is not collected.

---

## Sell Prices

Alpaca prices climb steadily up to 36 months and stay at that level for older animals. All four colours sell for the same.

### Typical Sell Prices ($)

| Age | Female | Male |
|-----|--------|------|
| Newborn | 280 | 470 |
| 12 mo | 1,440 | 2,700 |
| 24 mo | 2,900 - 3,650 | 4,600 - 5,750 |
| 36+ mo (peak) | **5,350 - 6,700** | **5,350 - 6,700** |

*These are typical prices for a healthy alpaca with average genetics, raised on hay. From 24 months the two figures run from no happiness to full happiness; the younger prices are for no happiness. Actual prices vary widely: at 36+ months a healthy, fully happy alpaca sells for under $1,000 with the poorest quality genetics and about $20,000 with the best, and a sick animal cannot be sold at the dealer until it recovers.*

### What Affects Sell Price

| Factor | Importance | What It Means |
|--------|------------|---------------|
| **Quality genetics** | Most important | Better genetics -> much higher value - this is the biggest factor |
| **Health** | Very important | Healthy alpacas sell for significantly more |
| **Weight** | Important | The price moves in step with weight for age, so a well-fed alpaca is worth considerably more than a thin one |
| **Happiness** | Important | A fully happy alpaca sells for noticeably more than one with no happiness |
| Castrated | Small | Small price bonus |
| Diseases | Blocks sale | A sick alpaca cannot be sold at the dealer until it recovers |

*Unlike most animals, a pregnant alpaca earns no price bonus.*

### Buy Prices

The dealer's price is the alpaca's own sale value plus a markup that depends on the [**Dealer Animal Quality**](reference-settings.md#dealer-ai) setting, plus a transport fee per alpaca. So it follows the same things as the sale value: age, genetics, health, weight and happiness. Buying into a trailer at the dealer has no transport fee.

Alpacas from the dealer arrive sheared, at no happiness and no fleece.

---

## Food & Water

Alpacas eat hay or grass, and hay feeds them better. They need no straw. Genetics significantly affect how much each animal eats - some are naturally much more efficient than others - and the Food Scale setting also adjusts consumption. Food and water rise through a pregnancy, more with a bigger litter: noticeably higher by the end.

### Food Consumption Range (L/month)

| | Newborn | 5+ mo (adult) |
|---|---------|---------------|
| **Female and male** | 3 - 18 | 25 - 175 |

*Ranges show the span from the most efficient to the hungriest animals.*

*Food and water figures are per in-game month, whatever your month length. The animal's info box shows them per day, so with 3 days per month it shows a third of these figures.*

### Water Consumption (L/month, newborn -> 5+ mo)

| | Water |
|---|-------|
| **Female and male** | 2 -> 20 |

---

## Weights

| | Birth | Target | Maximum |
|---|-------|--------|---------|
| **Female** | about 7.5 kg | 60 kg | 100 kg |
| **Male** | about 8 kg | 65 kg | 110 kg |

*Raised on hay, an alpaca reaches its target weight at about 30 months. Higher metabolism animals reach target weight faster but eat more. Metabolism also shifts each animal's own target weight: a high metabolism animal ends up noticeably above the target shown, a low metabolism animal noticeably below it.*

---

## Reproduction

| Parameter | Alpaca |
|-----------|--------|
| Female breeding age | 14+ months |
| Male breeding age | 24+ months |
| Male max breeding age | 120 months (10 years) |
| Female fertility ends | 180 months (15 years) |
| Gestation | 11 months |
| Min health to breed | 75% |

*See the [Breeding Reference](reference-breeding.md) for a side-by-side table of breeding ages, gestation, and litter sizes across all species.*

> **Note:** Males stop breeding at 120 months - earlier than the female's fertile period (180 months). Replace your males regularly!

Any male can breed with any female, whatever their colours, and a young takes either parent's colour with an even chance. An AI straw passes on the sire's genetics, but the young takes its mother's colour.

### Offspring per Birth

Mostly one young, and twins are down to chance.

| Outcome | Likelihood |
|---------|------------|
| 1 | Most likely |
| Twins | Uncommon |

*Litter size does not depend on age. Age does not change a female's chance of conceiving - fertility genetics do. That chance holds until her end age of 180 months, then stops outright. Only alpacas with poor fertility genetics slow down in their last stretch. Her first young arrives at about 26 months at the earliest. A mother cannot conceive again for 3 months after giving birth, so her next conception comes at the earliest 14 months after the last. Alpacas never lactate, so a mother goes back to her usual food and water after the birth.*

---

## Lifespan & Death

| Event | Age |
|-------|-----|
| Male stops breeding | 120 months (10 years) |
| Female stops breeding | 180 months (15 years) |
| Old age deaths begin | 180 months (15 years) |
| Maximum lifespan (rarely reached) | ~240 months (20 years) |

*Most animals die of old age well before the maximum lifespan; only the best health genetics get close. Old age deaths can begin as soon as breeding ends, and alpacas can also die of low health or in accidents. Death can be toggled off in settings.*

---

## Diseases

| Disease | Spread | Fatal? | Treatment | Impact |
|---------|--------|--------|-----------|--------|
| **Pulpy Kidney** | None | High - worst in the young | 1 month, $150 (cures about half the time) | Major price loss; considerably slower growth while sick; fleece is not affected |

*Pulpy kidney is the only disease alpacas can catch. It never passes between animals, and alpacas up to 12 months old catch it most often. The Fatal column holds while **Animal Death** is on. See the [Disease Guide](guide-diseases.md#pulpy-kidney) for detailed prevention and treatment.*

Alpacas can be vaccinated against pulpy kidney (12 months, $15 a dose), and the young of a protected mother are born protected for 2 months - see [Vaccination](guide-diseases.md#vaccination).

---

## Tips

1. **Keep them walking.** Happiness raises price, fleece and health, and it only comes from leading. With the worker's daily Leading task an alpaca has a full coat by each yearly shearing; left alone, it manages only about 60%.

2. **Feed hay.** An adult that is never led cannot stay healthy on grass alone. Hay keeps it healthy, and it is the better feed for young stock too.

3. **Breeding is slow.** A female has her first young at about 26 months at the earliest and can conceive only about every 14 months, so plan for a little under one young a year per female. Keep a male of 24 months or more in the pen.

4. **Buy for quality.** Quality genetics move the price more than anything else, so a well-bred alpaca is worth many times a poor one.

5. **Vaccinate the young.** Treatment for pulpy kidney cures only about half the time, while a $15 dose protects for 12 months.
