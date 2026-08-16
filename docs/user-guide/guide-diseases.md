# Disease Guide

Realistic Livestock RM includes five diseases that can infect, spread between, and kill your animals. Each disease affects specific species and has different transmission rates, fatality, and treatment options. Diseases can be toggled off entirely in settings.

> **Note:** This documentation was generated with AI assistance and may contain inaccuracies. If you spot an error, please [open an issue](https://github.com/rittermod/FS25_RealisticLivestockRM/issues).

---

## Disease Summary

| Disease | Species | Spread | Fatal | Treatable | Sell Price Impact |
|---------|---------|--------|-------|-----------|-------------------|
| **Mastitis** | Cow, Goat | Slow | No | Yes ($200) | Small reduction |
| **CVM** | Cow only | Genetic | Almost always (calves) | No | Moderate reduction |
| **Foot & Mouth** | Cow, Sheep, Goat, Pig | Moderate | Yes | Yes ($250/mo) | Major reduction |
| **PED** | Pig only | Moderate | Devastating to newborns | Yes ($150) | Significant reduction |
| **Avian Influenza** | Chicken only | Fast | Yes, high fatality | No | Severe reduction |

---

## How Sick, Cured, and Carrier Animals Show in the Lists

Only animals with a **currently active** disease are treated as sick by the animal lists: they
group under "Diseased Animals", sort to the top, and match the disease filter (`hasAnyDisease`).

### Reading the status icons

Each animal card carries a row of small icons along its bottom edge, to the right of the price.
Three of them describe health:

| Icon | Meaning |
|---|---|
| Medical bag (red) | Actively sick, with no treatment running |
| Pill bottle (blue) | Actively sick and **under treatment** |
| DNA strand (grey) | Carries a disease gene (CVM) |

The same row also carries the pregnancy, fertility and production icons, so a card can show a mix
of health and non-health icons at once.

An animal can show more than one health icon - a cow carrying CVM that also catches mastitis shows
both the DNA strand and a medical bag. A recovered animal serving out its immunity shows no health
icon at all, though a recovered CVM carrier still shows the DNA strand, because the carried gene is
for life. With diseases turned off in the settings, no card shows any health icon.

If you start a treatment and then stop it part-way, the course keeps the progress it has already
made - resuming picks up where it left off instead of starting the course again. The animal's
detail panel says so, reading **Treatment paused** rather than "Not treated". The card still shows
the red medical bag, because that icon answers "is a treatment running", and while the course is
paused the answer is no.

The icons replace the old red row tint, which could only say "something is wrong" and could not
tell an untreated animal from one you are already paying to treat. Marked animals keep their
orange tint, including when they are also sick. The older animal screen still uses the red tint.

One case reads oddly and is worth knowing: a cow that inherited CVM from **both** parents is
genuinely sick rather than a carrier, so it shows the red medical bag - but CVM has no treatment,
so there is nothing to start. Those animals rarely survive long.

### Two states that read as healthy

Two states look like a disease record in the animal's detail panel but read as **healthy**
everywhere else:

- **Cured animals.** After recovery the disease stays listed as "Immune" while the immunity
  countdown runs (12 or 24 months depending on the disease). The animal sits in its normal
  breed section, carries no status icon, and matches the "Healthy" filter. A recovered animal
  also stops spreading the disease, so an outbreak burns itself out as the survivors build up.
- **CVM carriers.** A carrier cow keeps its CVM entry for life, but it is not sick - it sits in
  its normal section and matches "Healthy" too. It does carry the grey DNA icon, so you can spot
  carriers from the list rather than opening each detail panel.

This also applies to herdsman rules built on the disease filter: a "sell animals with any
disease" rule sells only actively sick animals - it no longer selects cured animals or CVM
carriers. If you want to cull carriers, pick them manually from the detail panel.

> **Multiplayer note:** on a client, a fresh cure can keep showing as sick until the pen next
> syncs - which happens whenever an animal is bought, sold, moved, born, or dies in that pen.
> In an active herd that is usually the same in-game day; in a small, static pen it can take
> considerably longer. The server always has the correct state.

---

## Mastitis

**Affects:** Cows, Goats (lactating females only)

Mastitis is an udder infection that stops all milk production. It only affects animals that are currently lactating - non-lactating animals cannot contract it. Since sheep never lactate, they can never catch mastitis, and it never touches wool.

| Parameter | Value |
|-----------|-------|
| Spread | Slow - occasional transmission to nearby animals |
| Fatality | None - never kills |
| Treatment | $200, cured in 1 month |
| Natural recovery | 3 months without treatment |
| Immunity after recovery | 12 months |

### Impact on Production

| Impact | Effect |
|--------|--------|
| Milk / Goat milk | **Completely stopped** |
| Sell price | Small reduction |

### Management Tips

- Treat immediately ($200) to restore production in 1 month vs waiting 3 months for natural recovery
- After recovery, the animal is immune for 12 months
- Only lactating animals can get it - dry cows and males are safe
- In a large dairy herd, keep treatment funds available - mastitis is common

---

## CVM (Complex Vertebral Malformation)

**Affects:** Cattle only (genetic - not contagious)

CVM is a recessive genetic disease. It doesn't spread between animals - it's inherited from parents. CVM-affected calves almost always die within the first month of life.

| Parameter | Value |
|-----------|-------|
| Spread | None - inherited genetically |
| Fatality | Almost always fatal in affected calves (within first month) |
| Treatment | None |
| Carrier chance from dealer | Rare (about 1 in 200 cattle purchased) |

### Carrier Cows: The Trade-Off

CVM carriers appear healthy and suffer no ill effects. In fact, **CVM carrier cows produce substantially more milk** than non-carriers. This makes them extremely valuable for dairy - but also risky for breeding.

| Breeding Combination | Result |
|---------------------|--------|
| Non-carrier x Non-carrier | 100% healthy calves |
| Carrier x Non-carrier | 50% carriers, 50% non-carriers (all healthy) |
| Carrier x Carrier | ~25% affected (die), 50% carriers, 25% non-carriers |

### Management Tips

- Check all new cattle purchases for CVM carrier status
- Carrier cows are excellent milk producers - keep them, but breed carefully
- Never breed two carriers together unless you accept ~25% calf mortality
- Breed carriers with confirmed non-carriers for safe milk bonus
- CVM status is visible in the animal's disease panel

---

## Foot & Mouth Disease

**Affects:** Cows, Sheep, Goats, Pigs

Foot & Mouth is the most widespread disease, affecting three species. It's moderately contagious and can be fatal, especially in recently infected animals.

| Parameter | Value |
|-----------|-------|
| Spread | Moderate - noticeable risk to nearby animals |
| Fatality | Moderate initially, decreasing as the animal builds resistance |
| Treatment | $250/month ($750 over 3 months) |
| Natural recovery | None - requires treatment |
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
| Just infected | Moderate |
| After several months | Low, declining |
| Long-term survivors | Low but ongoing |

*Fatality falls the longer an animal stays infected, but it never reaches zero on its own - only a completed treatment does that, after which the animal faces no further risk from Foot & Mouth until its immunity lapses. For as long as the animal stays infected, chronic infection keeps draining production.*

### Management Tips

- Treat as soon as possible - the 3-month course is survivable, but it is not a guaranteed save, and
  starting it early is what decides the odds: an animal put on treatment as soon as it falls ill is
  roughly twice as likely to pull through as one left for six months first
- Budget $750 per animal - the $250 is charged again at the start of each of the three months, not
  once, so a whole-herd outbreak is expensive to treat your way out of
- Treating still beats leaving it alone by a wide margin - an untreated animal is the one most likely
  to die
- No natural recovery means untreated animals stay sick indefinitely
- Milk drops severely - devastating for dairy operations
- Sell price is greatly reduced - selling infected animals is a significant loss
- 24-month immunity after recovery provides long-term protection
- Can spread across cows, sheep, and pigs in adjacent pens (same husbandry)

---

## PED (Porcine Epidemic Diarrhea)

**Affects:** Pigs only

PED is devastating to young piglets - almost always fatal in newborns. Older pigs rarely catch it on their own, but any pig infected during an outbreak faces the same danger (see below).

| Parameter | Value |
|-----------|-------|
| Spread | Moderate - spreads to nearby pigs |
| Fatality | Almost always fatal in the first month after infection |
| Treatment | $150, cured in 1 month |
| Natural recovery | 3 months without treatment |
| Immunity after recovery | 12 months |

### Impact on Production

| Impact | Effect |
|--------|--------|
| Liquid manure | **Drastically increased** (diarrhea symptom) |
| Manure | Severely reduced |
| Sell price | Significant reduction |

### Fatality Over Time

| Time Since Infection | Death Risk |
|----------------------|------------|
| Just infected | **Almost always fatal** |
| After 1 month | Low risk |
| 2+ months | Very low - chronic survivors are stable |

*Fatality drops sharply after the first month. The reason newborns rarely survive PED is **not** that fatality changes with age - it's that newborns get infected far more often than adults (spontaneous infection is common at 0 mo, very rare from 24 mo onwards). Once infected, the bulk of deaths happen in the first month regardless of how old the pig was. Treatment cures a pig on the next month's tick and spares it that month's risk entirely; left alone, most pigs that survive their first month are cured within a few more. Either way a cured pig faces no further risk from PED until its immunity lapses.*

### Why PED Is Devastating

With pig litters of 11-16 piglets, a PED outbreak in a maternity pen can kill most of a generation in a single month. A sow producing 13 piglets might lose the vast majority of them.

### Management Tips

- Treatment is cheap ($150) and fast (1 month) - treat immediately
- Natural recovery takes 3 months, during which piglets continue dying
- Consider separating pregnant sows from infected animals
- Adult pigs rarely catch PED on their own - focus protection on newborns and on stopping outbreaks early
- If PED keeps recurring, consider the diseases toggle in settings

---

## Avian Influenza (Bird Flu)

**Affects:** Chickens only

Avian Flu is the fastest-spreading disease and has **no treatment**. Infected chickens stop producing eggs entirely and have a high fatality rate.

| Parameter | Value |
|-----------|-------|
| Spread | **Fast** - can infect multiple birds quickly |
| Fatality | High initially, then much lower while the bird stays infected; none once it recovers, until that immunity lapses |
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
| Just infected | **High - many birds die** |
| After 1 month | Much lower - risk drops sharply once past the first month |
| Recovered (immune) | **None** for the 24-month immunity |

*The first two rows apply while a bird is still infected. Recovery usually arrives after about a month, though some birds stay sick longer. A recovered bird can neither catch nor die of avian flu while its immunity lasts, and no longer spreads it to the flock; once that immunity lapses it can be infected again.*

### Why Avian Flu Is Dangerous

- **No treatment** - you can only wait for natural recovery (1 month)
- **Fast spread** - in a large pen, multiple birds get infected each month
- **High initial fatality** - many infected chickens die before recovering
- **Complete egg loss** - surviving infected chickens produce zero eggs
- Even survivors lose a month of egg production while sick

### Management Tips

- There is no treatment - prevention is the only strategy
- Sell infected birds quickly to limit spread and recover some value
- Keep smaller flocks in separate pens to limit outbreak damage
- Survivors gain 24-month immunity - while it lasts they cannot catch avian flu again, cannot die of it, and no longer spread it to the rest of the flock, though birds hatched or bought later have no such protection
- Chickens that survive gain immunity and will be your most valuable layers

---

## Disease Settings

Two settings control diseases globally:

| Setting | Default | Range | Effect |
|---------|---------|-------|--------|
| **Diseases Enabled** | On | On/Off | Toggles entire disease system |
| **Disease Chance** | 1x | 0.25-5x | Scales infection probability |

*Reducing Disease Chance to 0.25x makes diseases much less common. Setting to 5x makes them much more frequent. Disabling diseases suspends them - no new infections, spread, or effects; animals already infected are not cured, and their diseases resume if you re-enable the setting.*
