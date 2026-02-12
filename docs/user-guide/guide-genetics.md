# Genetics Guide

Every animal in Realistic Livestock RM is born with a unique set of genetic traits that affect its production, value, health, and appetite. Understanding genetics is key to building a profitable herd through selective breeding.

> **Note:** This documentation was generated with AI assistance and may contain inaccuracies. If you spot an error, please [open an issue](https://github.com/rittermod/FS25_RealisticLivestockRM/issues).

---

## The Five Traits

| Trait | In-Game Label | Affects | Applies To |
|-------|---------------|---------|------------|
| **Health** | Health | Disease resistance, longevity | All animals |
| **Fertility** | Fertility | Breeding success rate | All animals |
| **Productivity** | Milk / Wool / Eggs | Production output amount | Cows, Sheep, Goats, Chickens |
| **Quality** | Meat | Sell price and meat value | All animals |
| **Metabolism** | Metabolism | Food consumption and weight gain | All animals |

> **Productivity** is species-specific: it shows as "Milk" for cows, "Wool" for sheep, and "Eggs" for chickens. Pigs and horses don't have this trait — they have no special production output.

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
| **Infertile** | Animal can never breed (extremely rare — about 1 in 1,000) |

*Infertile animals can still produce milk/wool/eggs — they just can't reproduce.*

---

## What Each Trait Does

### Health

- Affects how quickly health recovers or deteriorates
- Higher health genetics = more resistant to disease effects
- Animals below 80% health face monthly death risk — good health genetics help stay above this threshold
- **Impact:** Survival and longevity

### Fertility

- Directly affects the chance of successful breeding
- Higher fertility = more likely to produce offspring each breeding cycle
- Extremely rare chance of being born completely infertile (about 1 in 1,000)
- **Impact:** Breeding success rate

### Productivity — Cows, Sheep, Goats, Chickens

- Directly scales production output (milk, wool, eggs, goat milk)
- An animal with Extremely High productivity produces many times more than one with Extremely Low
- The large production ranges shown in each factsheet are primarily driven by this trait
- **Impact:** The single biggest factor in milk, wool, and egg output

*Pigs and horses don't have productivity — they have no special production output.*

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

Animals purchased from the dealer have randomised genetics. Most will be average, but you might occasionally find an exceptional animal — or a terrible one. Check genetics before buying when possible.

---

## Breeding & Inheritance

Offspring inherit traits from both parents. While the exact inheritance mechanism depends on both parent values, selective breeding works:

- Breeding two high-productivity cows tends to produce higher-productivity calves
- Breeding two animals with poor genetics risks passing those traits on
- Over multiple generations, focused selection can significantly improve your herd's average genetics

### Breeding Strategy

1. **Identify your goals:** Milk production? Sell value? Low feed cost?
2. **Check genetics** on all animals before breeding
3. **Keep the best:** Animals with High or Very High in your target trait
4. **Sell the rest:** Animals with Low or worse in key traits
5. **Be patient:** Genetic improvement takes multiple generations

---

## The CVM Dilemma

CVM (Complex Vertebral Malformation) is a genetic disease unique to cattle. It follows recessive inheritance:

| Parent Combination | Offspring |
|-------------------|-----------|
| Non-carrier × Non-carrier | All non-carrier |
| Carrier × Non-carrier | 50% carrier, 50% non-carrier |
| **Carrier × Carrier** | **~25% affected (almost always fatal), 50% carrier, 25% non-carrier** |

### The Trade-Off

**CVM carrier cows produce substantially more milk than normal.** This makes them extremely valuable for dairy operations — but breeding two carriers together risks producing affected calves that will almost certainly die.

| Strategy | Benefit | Risk |
|----------|---------|------|
| Keep carriers, breed with non-carriers | Much more milk, no affected calves | 50% of offspring are still carriers |
| Breed carriers together | Maximum milk potential | ~25% of calves die |
| Remove all carriers | No CVM risk | Lose the milk bonus |

**Identifying carriers:** CVM shows in the animal's disease panel. Carriers show as having CVM but remain healthy and productive. Affected animals are the ones that die.

**Dealer animals:** There's a small chance (about 1 in 200) of any cow purchased from the dealer being a CVM carrier. Check new purchases!

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
