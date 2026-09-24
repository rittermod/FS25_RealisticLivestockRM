# Genetics Guide

Every animal in Realistic Livestock RM is born with a unique set of genetic traits that affect its production, value, health, and appetite. Understanding genetics is key to building a profitable herd through selective breeding.

> **Note:** This documentation was generated with AI assistance and may contain inaccuracies. If you spot an error, please [open an issue](https://github.com/rittermod/FS25_RealisticLivestockRM/issues).

---

## The Five Traits

| Trait | In-Game Label | Affects | Applies To |
|-------|---------------|---------|------------|
| **Health** | Health | Surviving a disease, longevity | All animals |
| **Fertility** | Fertility | Breeding success rate | All animals |
| **Productivity** | Milk / Wool / Eggs | Production output amount | Cows, Sheep, Goats, Chickens |
| **Quality** | Meat | Sell price and meat value | All animals |
| **Metabolism** | Metabolism | Food consumption and weight gain | All animals |

> **Productivity** is species-specific: it shows as "Milk" for cows, "Wool" for sheep, and "Eggs" for chickens. Pigs and horses don't have this trait - they have no special production output.

> **Metabolism** is double-edged: high metabolism means faster weight gain but also higher food costs. Low metabolism means cheaper to feed but slower growth.

---

## Rating Scale

Each trait is displayed in-game with a rating and colour:

| Rating | Colour | Rarity |
|--------|--------|--------|
| **Extremely High** | Green | Rare (~5%) |
| **Very High** | Light Green | Uncommon |
| **High** | Yellow-Green | Fairly common |
| **Average** | Yellow | Most common (~50%) |
| **Low** | Orange | Fairly common |
| **Very Low** | Dark Orange | Uncommon |
| **Extremely Low** | Red | Rare (~5%) |

*The overall genetics rating uses Good/Bad labels instead of High/Low, calculated from the average of all traits.*

### Special Case: Fertility

Fertility has one additional rating:

| Rating | Meaning |
|--------|---------|
| **Infertile** | Animal can never breed (extremely rare - about 1 in 1,000) |

*Infertile animals can still produce milk/wool/eggs - they just can't reproduce.*

---

## What Each Trait Does

### Health

- Affects how quickly health recovers or deteriorates
- Higher health genetics = more likely to survive a disease (they do not make an animal less likely to catch one)
- Animals below 80% health face monthly death risk - good health genetics help stay above this threshold
- **Impact:** Survival and longevity

### Fertility

- Directly affects the chance of successful breeding
- Higher fertility = more likely to produce offspring each breeding cycle
- Extremely rare chance of being born completely infertile (about 1 in 1,000)
- **Impact:** Breeding success rate

### Productivity - Cows, Sheep, Goats, Chickens

- Directly scales production output (milk, wool, eggs, goat milk)
- An animal with Extremely High productivity produces many times more than one with Extremely Low
- The large production ranges shown in each factsheet are primarily driven by this trait
- **Impact:** The single biggest factor in milk, wool, and egg output

*Pigs and horses don't have productivity - they have no special production output.*

### Quality / Meat

- Directly affects sell price
- Higher quality = better meat value = higher sell price
- **Impact:** All animals sell for more or less based on this trait

### Metabolism

- Affects both food consumption and weight gain
- **Double-edged trait:**
  - High metabolism: Eats significantly more, grows faster, reaches target weight sooner
  - Low metabolism: Eats much less, grows slower, cheaper to maintain long-term
- The large food consumption ranges shown in each factsheet are primarily driven by this trait
- **Impact:** Determines how expensive an animal is to feed

---

## Distribution

Most animals are average. The distribution follows a bell curve:

| Category | Approximate Chance |
|----------|--------------------|
| Bottom tier (Extremely Low) | ~5% |
| Below average (Low to Very Low) | ~20% |
| **Average** | **~50%** |
| Above average (High to Very High) | ~20% |
| Top tier (Extremely High) | ~5% |

*Each trait is rolled independently. An animal can have excellent health but terrible productivity.*

### Dealer Animals

Animals purchased from the dealer have randomised genetics. Most will be average, but you might occasionally find an exceptional animal - or a terrible one. Check genetics before buying when possible.

---

## Breeding & Inheritance

Offspring inherit traits from both parents. The mod calculates the average of both parents' trait values, then adds random variation. This means:

- Breeding two high-productivity cows **tends** to produce higher-productivity calves
- But individual offspring can end up better or worse than either parent
- Breeding two animals with poor genetics risks passing those traits on
- Over multiple generations, focused selection can significantly improve your herd's average genetics

> **Important:** High-genetics parents don't guarantee high-genetics offspring. Without active herd management, genetics will drift towards average over generations - a real phenomenon called *regression to the mean*. See the [FAQ](faq.md#how-can-offspring-have-worse-genetics-than-their-parents) for a full explanation.

### Breeding Strategy

1. **Identify your goals:** Milk production? Sell value? Low feed cost?
2. **Check genetics** on all animals before breeding
3. **Keep the best:** Animals with High or Very High in your target trait
4. **Sell or castrate the rest:** Remove animals with Low or worse genetics from your breeding stock - don't let them reproduce
5. **Be patient:** Genetic improvement takes multiple generations and active culling each generation

---

## The CVM Dilemma

CVM (Complex Vertebral Malformation) is a genetic disease unique to cattle. It is never caught and never spreads - it follows recessive inheritance, settled at conception:

| Parent Combination | Offspring |
|-------------------|-----------|
| Non-carrier × Non-carrier | All non-carrier |
| Carrier × Non-carrier | 50% carrier, 50% non-carrier |
| **Carrier × Carrier** | **25% affected, 50% carrier, 25% non-carrier** |

At conception an affected parent passes the gene to every calf: with a non-carrier every calf is a carrier, and with a carrier half the calves are affected. Artificial insemination, or a conception with no live bull, counts the cow's genes only.

- **Carriers** (one copy) are healthy for life and never sick from CVM.
- **Affected animals** (two copies) are sick from birth and cannot be treated; with **Animal Death** on they die within a few months.

### The Trade-Off

**CVM carrier cows produce considerably more milk than non-carriers** while the **Diseases** setting is on. This makes them valuable for dairy operations - but breeding two carriers together risks producing affected calves.

| Strategy | Benefit | Risk |
|----------|---------|------|
| Keep carriers, breed with non-carriers | More milk, no affected calves | 50% of offspring are still carriers |
| Breed carriers together | None over carrier × non-carrier - it gives the same 50% carriers | 25% of calves are affected |
| Remove all carriers | No CVM risk | Lose the milk bonus |

**Identifying carriers:** a carrier shows the grey DNA icon on its card, and CVM is listed in its detail panel. Carriers remain healthy and productive; affected animals show the red medical bag and, with **Animal Death** on, are the ones that die.

**Dealer animals:** about 1 in 200 dealer cattle carry the gene - most as carriers, a few affected. Check new purchases!

Inheritance and dealer stock carrying the gene need the **Diseases** setting on and CVM ticked under **Choose Diseases** - see the [Disease Guide](guide-diseases.md#disease-settings).

---

## Overall Genetics Rating

The game displays an "Overall" genetics rating that combines all traits:

| Overall Rating | Meaning |
|---------------|---------|
| Extremely Good | Top-tier animal across all traits |
| Very Good | Above average in most traits |
| Good | Slightly above average overall |
| Average | Normal animal |
| Bad | Below average in several traits |
| Very Bad | Poor in most traits |
| Extremely Bad | Bottom-tier across all traits |

*The overall rating is calculated from the average of all applicable traits. Use it as a quick quality indicator, but check individual traits for specific breeding decisions.*
