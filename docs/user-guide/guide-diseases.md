# Disease Guide

Realistic Livestock RM includes five diseases that can infect, spread between, and kill your animals. Each disease affects specific species and has different transmission rates, fatality, and treatment options. Diseases can be toggled off entirely in settings.

> **Note:** This documentation was generated with AI assistance and may contain inaccuracies. If you spot an error, please [open an issue](https://github.com/rittermod/FS25_RealisticLivestockRM/issues).

---

## Disease Summary

| Disease | Species | Spread | Fatal | Treatable | Sell Price Impact |
|---------|---------|--------|-------|-----------|-------------------|
| **Mastitis** | Cow, Sheep, Goat | Slow | No | Yes ($200) | Small reduction |
| **CVM** | Cow only | Genetic | Almost always (calves) | No | Moderate reduction |
| **Foot & Mouth** | Cow, Sheep, Pig | Moderate | Yes | Yes ($250) | Major reduction |
| **PED** | Pig only | Moderate | Devastating to newborns | Yes ($150) | Significant reduction |
| **Avian Influenza** | Chicken only | Fast | Yes, high fatality | No | Severe reduction |

---

## Mastitis

**Affects:** Cows, Sheep, Goats (lactating females only)

Mastitis is an udder infection that stops all milk and wool production. It only affects animals that are currently lactating — non-lactating animals cannot contract it.

| Parameter | Value |
|-----------|-------|
| Spread | Slow — occasional transmission to nearby animals |
| Fatality | None — never kills |
| Treatment | $200, cured in 1 month |
| Natural recovery | 3 months without treatment |
| Immunity after recovery | 12 months |

### Impact on Production

| Impact | Effect |
|--------|--------|
| Milk / Goat milk / Wool | **Completely stopped** |
| Sell price | Small reduction |

### Management Tips

- Treat immediately ($200) to restore production in 1 month vs waiting 3 months for natural recovery
- After recovery, the animal is immune for 12 months
- Only lactating animals can get it — dry cows and males are safe
- In a large dairy herd, keep treatment funds available — mastitis is common

---

## CVM (Complex Vertebral Malformation)

**Affects:** Cattle only (genetic — not contagious)

CVM is a recessive genetic disease. It doesn't spread between animals — it's inherited from parents. CVM-affected calves almost always die within the first month of life.

| Parameter | Value |
|-----------|-------|
| Spread | None — inherited genetically |
| Fatality | Almost always fatal in affected calves (within first month) |
| Treatment | None |
| Carrier chance from dealer | Rare (about 1 in 200 cattle purchased) |

### Carrier Cows: The Trade-Off

CVM carriers appear healthy and suffer no ill effects. In fact, **CVM carrier cows produce substantially more milk** than non-carriers. This makes them extremely valuable for dairy — but also risky for breeding.

| Breeding Combination | Result |
|---------------------|--------|
| Non-carrier x Non-carrier | 100% healthy calves |
| Carrier x Non-carrier | 50% carriers, 50% non-carriers (all healthy) |
| Carrier x Carrier | ~25% affected (die), 50% carriers, 25% non-carriers |

### Management Tips

- Check all new cattle purchases for CVM carrier status
- Carrier cows are excellent milk producers — keep them, but breed carefully
- Never breed two carriers together unless you accept ~25% calf mortality
- Breed carriers with confirmed non-carriers for safe milk bonus
- CVM status is visible in the animal's disease panel

---

## Foot & Mouth Disease

**Affects:** Cows, Sheep, Pigs

Foot & Mouth is the most widespread disease, affecting three species. It's moderately contagious and can be fatal, especially in recently infected animals.

| Parameter | Value |
|-----------|-------|
| Spread | Moderate — noticeable risk to nearby animals |
| Fatality | High initially, decreasing as the animal builds resistance |
| Treatment | $250, cured in 3 months |
| Natural recovery | None — requires treatment |
| Immunity after recovery | 24 months |

### Impact on Production

| Impact | Effect |
|--------|--------|
| Milk (cow) | **Severely reduced** (about two-thirds less) |
| Wool / Goat milk | Slightly reduced |
| Sell price | **Major reduction** |

### Fatality Over Time

| Time Infected | Death Risk |
|--------------|------------|
| Just infected | High |
| After several months | Moderate, declining |
| Long-term survivors | Low but ongoing |

*Fatality decreases the longer the animal survives, but without treatment, chronic infection keeps draining production.*

### Management Tips

- Treat as soon as possible — 3 months is a long treatment but necessary
- No natural recovery means untreated animals stay sick indefinitely
- Milk drops severely — devastating for dairy operations
- Sell price is greatly reduced — selling infected animals is a significant loss
- 24-month immunity after recovery provides long-term protection
- Can spread across cows, sheep, and pigs in adjacent pens (same husbandry)

---

## PED (Porcine Epidemic Diarrhea)

**Affects:** Pigs only

PED is devastating to young piglets — almost always fatal in newborns. Older pigs survive more easily, making this the most age-dependent disease in the mod.

| Parameter | Value |
|-----------|-------|
| Spread | Moderate — spreads to nearby pigs |
| Fatality | Almost always fatal in newborns, rarely fatal in older pigs |
| Treatment | $150, cured in 1 month |
| Natural recovery | 3 months without treatment |
| Immunity after recovery | 12 months |

### Impact on Production

| Impact | Effect |
|--------|--------|
| Liquid manure | **Drastically increased** (diarrhea symptom) |
| Manure | Greatly reduced |
| Sell price | Significant reduction |

### Fatality by Age

| Age When Infected | Death Risk |
|-------------------|------------|
| Newborn (0 mo) | **Almost always fatal** |
| 1 month old | Moderate risk |
| 2+ months | Very low — adults survive easily |

*PED is almost exclusively fatal in newborn piglets. Adult pigs survive easily.*

### Why PED Is Devastating

With pig litters of 11–16 piglets, a PED outbreak in a maternity pen can kill most of a generation in a single month. A sow producing 13 piglets might lose the vast majority of them.

### Management Tips

- Treatment is cheap ($150) and fast (1 month) — treat immediately
- Natural recovery takes 3 months, during which piglets continue dying
- Consider separating pregnant sows from infected animals
- Adult pigs are essentially immune to PED fatality — focus protection on newborns
- If PED keeps recurring, consider the diseases toggle in settings

---

## Avian Influenza (Bird Flu)

**Affects:** Chickens only

Avian Flu is the fastest-spreading disease and has **no treatment**. Infected chickens stop producing eggs entirely and have a high fatality rate.

| Parameter | Value |
|-----------|-------|
| Spread | **Fast** — can infect multiple birds quickly |
| Fatality | Very high initially, decreasing for survivors |
| Treatment | **None available** |
| Natural recovery | 1 month |
| Immunity after recovery | 24 months |

### Impact on Production

| Impact | Effect |
|--------|--------|
| Eggs | **Completely stopped** |
| Sell price | Severe reduction |

### Fatality Over Time

| Time Infected | Death Risk |
|--------------|------------|
| Just infected | **Very high — most birds die** |
| After 1–2 months | High |
| 3+ months (survivors) | Moderate but ongoing |

### Why Avian Flu Is Dangerous

- **No treatment** — you can only wait for natural recovery (1 month)
- **Fast spread** — in a large pen, multiple birds get infected each month
- **Very high initial fatality** — most infected chickens die before recovering
- **Complete egg loss** — surviving infected chickens produce zero eggs
- Even survivors lose a month of egg production while sick

### Management Tips

- There is no treatment — prevention is the only strategy
- Sell infected birds quickly to limit spread and recover some value
- Keep smaller flocks in separate pens to limit outbreak damage
- Survivors gain 24-month immunity, creating a resistant flock over time
- Chickens that survive gain immunity and will be your most valuable layers

---

## Disease Settings

Two settings control diseases globally:

| Setting | Default | Range | Effect |
|---------|---------|-------|--------|
| **Diseases Enabled** | On | On/Off | Toggles entire disease system |
| **Disease Chance** | 1x | 0.25–5x | Scales infection probability |

*Reducing Disease Chance to 0.25x makes diseases much less common. Setting to 5x makes them much more frequent. Disabling diseases removes them entirely.*
