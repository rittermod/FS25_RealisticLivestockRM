# Genetics Guide

Every animal in Realistic Livestock RM is born with a unique set of genetic traits that affect its production, value, health, and appetite. Understanding genetics is key to building a profitable herd through selective breeding.

> **Note:** This documentation was generated with AI assistance and may contain inaccuracies. If you spot an error, please [open an issue](https://github.com/rittermod/FS25_RealisticLivestockRM/issues).

---

## The Five Traits

| Trait | In-Game Label | Affects | Applies To |
|-------|---------------|---------|------------|
| **Health** | Health | Surviving a disease, longevity | All animals |
| **Fertility** | Fertility | Breeding success rate | All animals |
| **Productivity** | Milk production / Wool production / Egg production / Fleece production | Production output amount | Cows, Sheep, Goats, Chickens, Alpacas |
| **Quality** | Quality or Meat Quality | Sell price and meat value | All animals |
| **Metabolism** | Metabolism | Food consumption and weight gain | All animals |

> **Productivity** is species-specific: it shows as "Milk production" for cows and goats, "Wool production" for sheep, "Egg production" for chickens, and "Fleece production" for [alpacas](factsheet-alpacas.md). Pigs and horses don't have this trait - they have no special production output.

> **Metabolism** is double-edged: high metabolism means faster weight gain but also higher food costs. Low metabolism means cheaper to feed but slower growth.

---

## Rating Scale

Each trait is displayed in-game with a rating and colour:

| Rating | Colour |
|--------|--------|
| **Extremely High** | Green |
| **Very High** | Light Green |
| **High** | Yellow-Green |
| **Average** | Yellow |
| **Low** | Orange |
| **Very Low** | Dark Orange |
| **Extremely Low** | Red |

*How common each rating is depends on where the animal came from - see [Distribution](#distribution). The overall genetics rating uses Good/Bad labels instead of High/Low, calculated from the average of all traits.*

### Special Case: Fertility

Fertility has one additional rating:

| Rating | Meaning |
|--------|---------|
| **Infertile** | Animal can never breed: born infertile (extremely rare, except for [freemartin](guide-breeding.md#freemartin-effect-cattle-only) heifers, which almost always are), or a castrated male |

*Infertile animals still produce wool, fleece and eggs, but milk only starts after a birth, so an infertile cow or goat never gives milk. Castrating a male does not change his other genetics or his overall rating.*

---

## What Each Trait Does

### Health

- Affects how quickly health recovers or deteriorates
- Higher health genetics = more likely to survive a disease (they do not make an animal less likely to catch one)
- Animals in poor health face a daily death risk - good health genetics lower it and help keep health up
- **Impact:** Survival and longevity

### Fertility

- Directly affects the chance of successful breeding
- Higher fertility = more likely to produce offspring each breeding cycle
- Extremely rare chance of being born completely infertile, and a [freemartin](guide-breeding.md#freemartin-effect-cattle-only) heifer is almost always infertile
- **Impact:** Breeding success rate

### Productivity - Cows, Sheep, Goats, Chickens, Alpacas

- Directly scales production output (milk, wool, eggs, goat milk, fleece)
- An animal with Extremely High productivity produces many times more than one with Extremely Low
- The large production ranges shown in each factsheet are primarily driven by this trait
- **Impact:** The single biggest factor in milk, wool, fleece and egg output

*Pigs and horses don't have productivity - they have no special production output.*

### Quality

- Directly affects sell price
- Higher quality = better meat value = higher sell price
- **Impact:** All animals sell for more or less based on this trait

### Metabolism

- Affects both food consumption and weight gain
- **Double-edged trait:**
  - High metabolism: Eats significantly more, grows faster, reaches target weight sooner
  - Low metabolism: Eats much less, grows slower, cheaper to maintain long-term
- It also moves each animal's own target weight: noticeably higher with high metabolism, noticeably lower with low metabolism
- The large food consumption ranges shown in each factsheet are primarily driven by this trait
- **Impact:** Determines how expensive an animal is to feed

---

## Distribution

How likely each rating is depends on where the animal came from. Dealer stock is what the dealer offers you. Animals the mod rolls itself are ones that reach a pen another way, such as animals placed by the base game or another mod. Bred animals take their genetics from their parents - see [Breeding & Inheritance](#breeding-inheritance).

| Category | Dealer stock (Standard quality) | Animals the mod rolls itself |
|----------|---------------------------------|------------------------------|
| Bottom tier (Extremely Low) | About 1 in 50 | About 1 in 20 |
| Below average (Low to Very Low) | About 2 in 5 | About 1 in 5 |
| **Average** | **About 1 in 5** | **About 1 in 2** |
| Above average (High to Very High) | About 2 in 5 | About 1 in 5 |
| Top tier (Extremely High) | About 1 in 50 | About 1 in 20 |

*Animals the mod rolls itself get a separate roll for each trait, and bred animals inherit each trait separately, so both can have excellent health but terrible productivity.*

### Dealer Animals

Each animal the dealer offers gets one overall quality roll, and all its traits sit close to that. So a dealer animal tends to be good all round or poor all round, not strong in one trait and weak in another. At the default **Standard** setting of [Dealer Animal Quality](reference-settings.md#dealer-ai) this gives a wide spread, with Average about 1 in 5 and the extreme ratings about 1 in 50. **Budget** stock is mostly Low and Very Low, **Premium** stock is mostly High and Very High, and a few animals in each fall outside that band. Check genetics before buying when possible.

---

## Breeding & Inheritance

Offspring inherit traits from both parents. The mod calculates the average of both parents' trait values, then adds random variation. This means:

- Breeding two high-productivity cows **tends** to produce higher-productivity calves
- But individual offspring can end up better or worse than either parent
- Breeding two animals with poor genetics risks passing those traits on
- Over multiple generations, focused selection can significantly improve your herd's average genetics

> **Important:** High-genetics parents don't guarantee high-genetics offspring. Each young centres on the average of its two parents, then varies up or down, so a herd left alone keeps about the same average and just spreads wider. At the very top the genetic ceiling trims the luckiest rolls, so the very best parents usually have young a little below them. See the [FAQ](faq.md#how-can-offspring-have-worse-genetics-than-their-parents) for a full explanation.

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

*The overall rating is calculated from the average of all applicable traits. Use it as a quick quality indicator, but check individual traits for specific breeding decisions.*
