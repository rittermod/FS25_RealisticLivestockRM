# Disease Guide

Realistic Livestock RM has nine diseases that can make your animals sick and, with **Animal Death** on, kill them; most of them also spread through a pen. Each one affects specific animals and differs in whether and how fast it spreads, how dangerous it is and whether it can be treated. The **Diseases** setting sets how often animals fall ill and how fast diseases spread - see [Difficulty Levels](#difficulty-levels).

> **Note:** This documentation was generated with AI assistance and may contain inaccuracies. If you spot an error, please [open an issue](https://github.com/rittermod/FS25_RealisticLivestockRM/issues).

---

## Disease Summary

| Disease | Affects | Spread | Fatal (untreated) | Treatment | Value While Sick |
|---------|---------|--------|-------------------|-----------|------------------|
| **Mastitis** | Lactating cows and goats | Slow | Low - rarely | 1 month, $200 | Small reduction |
| **CVM** | Cattle (genetic) | None - inherited | Affected animals: almost always | None | Moderate reduction (affected animals only) |
| **Foot and Mouth** | Cows, sheep, goats, pigs | Fast | Low to moderate | 1 month, $250 | Major reduction |
| **Porcine Epidemic Diarrhoea (PED)** | Pigs | Moderate | Moderate - worst in young piglets | 1 month, $150 | Major reduction |
| **Avian Flu (LPAI)** | Chickens | Moderate | Low | 1 month, $5 | Severe reduction |
| **Avian Flu (HPAI)** | Chickens | Fast | Almost always fatal | None - cull | Severe reduction |
| **BRD** | Cattle | Moderate | Moderate - worst in calves | 1 month, $300 | Moderate reduction |
| **Pulpy Kidney** | Sheep, goats | None | High - worst in lambs and kids | 1 month, $150 (cures about half the time) | Major reduction |
| **Colic** | Horses | None | Moderate | 1 month, $500 (cures about half the time) | Major reduction |

*The Fatal column holds while **Animal Death** is on (the ModHub build labels the setting "Animal Removal"). With it off, no animal dies of a disease: every disease but CVM ends in recovery, and an animal affected by CVM stays sick.*

---

## How a Disease Runs Its Course

### Catching a disease

An animal catches a disease in one of two ways: on its own, from a small monthly chance that depends on its age, or from a sick animal in the same pen. A disease never passes between pens. How fast it spreads inside a pen depends on the share of the pen that is sick.

Animals that are sick - and, on **Hard** and **Very hard**, animals still in the hidden phase - spread the disease. Recovered and immune animals do not, and neither does CVM. Pulpy kidney, colic and CVM never spread at all. An animal that recovers or is culled stops spreading the disease from the next day.

While an animal travels in a livestock trailer its diseases are paused: it catches nothing, its illness does not progress or spread, it cannot die of it, and no treatment is charged.

### Keeping a case from spreading

On **Easy** and **Normal**, moving a sick animal into an empty pen on the day it shows symptoms usually stops it infecting the rest - foot and mouth, the fastest spreader among the treatable diseases, needs moving that same day. On **Hard** and **Very hard** a case has often spread already while it was hidden, so moving it helps less. You can move a sick animal between your own pens, and onto or off a livestock trailer, at any time.

### The hidden phase

On **Hard** and **Very hard**, most diseases start with a short hidden phase (see [Difficulty Levels](#difficulty-levels)). While it lasts the animal looks healthy everywhere - no status icon, nothing in the detail panel, the HUD or the Diseases dialog, and no message - and it cannot be treated or culled. It can still be sold.

A hidden case already spreads the disease, if the disease spreads at all, and its production already moves about half-way towards the sick effect: a milking cow gives less milk, and a pig with PED already makes more liquid manure. Growth and the chance to conceive are not affected until symptoms show. A milking cow with an active monitor shows the change in its output rows; a hen's egg row rarely shows it, and in a pen's total production it is easy to miss.

Avian Flu (HPAI), colic and CVM have no hidden phase on any level, and on **Easy** and **Normal** no disease has one: an animal shows symptoms on the day it falls ill.

### Symptoms and messages

When a disease shows in an animal in one of your pens, a "Contracted" message posts that day and the animal's card gets a status icon (see [Reading the status icons](#reading-the-status-icons)). When it recovers - whether a treatment cured it or it got better on its own - a "Cured from" message posts on that day. CVM posts neither message. If a course of treatment ends without curing the animal, an "ended without a cure" message posts that day.

### Treatment

Treat a sick animal from the **Diseases** dialog: open it from the RL Menu's Info tab, where **D** ("Animal Diseases" in Controls) opens it too. Every treatable disease has a 1-month course. The dialog shows the fee per month, and it is charged day by day while the course runs, so a finished course costs about the listed fee in total.

You can stop a course and resume it later. A stopped course keeps the progress it has made and costs nothing while it is stopped, and the detail panel reads **Treatment paused**.

A course that cures ends the illness when it finishes (for the two diseases whose course can fail, see [Treatment that fails](#treatment-that-fails)); it does not protect the animal before then, so an animal can still die while it is being treated. An animal in the hidden phase cannot be treated.

### Treatment that fails

A course for pulpy kidney or colic cures only about half the time. When a course fails, a message says the treatment ended without a cure, the status goes back to **Not treated** and the red medical bag returns. You can start a new course straight away. For every other treatable disease, a course that runs to the end cures the animal.

### Natural recovery

For every disease but Avian Flu (HPAI) and CVM, an untreated animal stays sick for at least 2 months unless it dies first, and after that has a chance to recover every day - so how long an untreated illness lasts varies. While **Animal Death** is on, a bird with HPAI rarely survives it. CVM never recovers.

### Death risk

Diseases kill only while **Animal Death** is on. A sick animal faces a risk every day it is sick, and that risk does not change with how long it has been ill; it ends when the animal recovers or is cured. For every disease but CVM there is no risk on the day symptoms first show.

Young animals, old animals and animals with poor health genetics are more at risk; the animal's current health does not change it. An animal affected by CVM is the exception: its risk is the same whatever its age and genetics.

### Immunity

An animal that recovers is immune to that disease for a time - between 6 and 24 months depending on the disease (see each disease below). While immune it cannot catch that disease again and does not spread it, and its detail panel lists the disease as **Immune** with the time left. When the immunity runs out the entry disappears and the animal can catch the disease again.

---

## Difficulty Levels

The **Diseases** setting has five levels:

| Level | How often animals fall ill | How fast diseases spread | Hidden phase |
|-------|----------------------------|--------------------------|--------------|
| **Off** | Never - see [Disease Settings](#disease-settings) | - | - |
| **Easy** | Rarely | Slowly | None - symptoms show at once |
| **Normal** (default) | Now and then | At a moderate pace | None - symptoms show at once |
| **Hard** | Often | Fast | Most diseases take a while to show symptoms |
| **Very hard** | Very often | Very fast | Most diseases take even longer to show symptoms |

No level changes the death risk, treatment, natural recovery or immunity: those are the same on every level. **Off** is a pause, not a cure - see [Disease Settings](#disease-settings). The [Settings Reference](reference-settings.md#diseases) has the setting's full text.

---

## How Sick, Recovered, and Carrier Animals Show in the Lists

Only animals showing symptoms count as sick in the animal lists: they group under "Diseased Animals", sort to the top, and match the disease filter.

### Reading the status icons

Each animal card carries a row of small icons along its bottom edge, to the right of the price.
The health icons are:

| Icon | Meaning |
|---|---|
| Medical bag (red) | Showing symptoms, with no treatment running |
| Pill bottle (blue) | Showing symptoms and **under treatment** |
| DNA strand (grey) | Carries a disease gene (CVM) |

The same row also carries the pregnancy, fertility and production icons, so a card can show a mix
of health and non-health icons at once.

An animal can show more than one health icon - a cow carrying CVM that also catches mastitis shows
both the DNA strand and a medical bag. A recovered animal serving out its immunity shows no health
icon at all, though a recovered CVM carrier still shows the DNA strand, because the carried gene is
for life. With the **Diseases** setting on **Off**, no card shows any health icon.

If you stop a treatment part-way, the course keeps the progress it has already made - resuming
picks up where it left off instead of starting the course again. The animal's detail panel says so,
reading **Treatment paused** rather than "Not treated". The card still shows the red medical bag,
because that icon answers "is a treatment running", and while the course is paused the answer is no.

The icons replace the old red row tint, which could only say "something is wrong" and could not
tell an untreated animal from one you are already paying to treat. Marked animals keep their
orange tint, including when they are also sick. The older animal screen still uses the red tint.

One case reads oddly and is worth knowing: a cow that inherited CVM from **both** parents is
genuinely sick rather than a carrier, so it shows the red medical bag and reads **Not treated** -
but CVM has no treatment, so there is nothing to start. With **Animal Death** on, such an animal
dies within a few months.

### States that read as healthy

These states can hide a disease record behind an animal that reads as **healthy** in the lists:

- **Recovered animals.** After recovery the disease stays listed as "Immune" in the detail panel
  while the immunity runs. The animal sits in its normal breed section, carries no status icon,
  and matches the "Healthy" filter.
- **CVM carriers.** A carrier keeps its CVM entry for life, but it is not sick - it sits in its
  normal section and matches "Healthy" too. It does carry the grey DNA icon, so you can spot
  carriers from the list rather than opening each detail panel.
- **Animals in the hidden phase** (**Hard** and **Very hard** only). Nothing shows anywhere until
  symptoms appear - see [The hidden phase](#the-hidden-phase).

This also applies to herdsman rules built on the disease filter: a rule for animals with any
disease selects only animals showing symptoms - never recovered animals, hidden cases or CVM
carriers. A sick animal cannot be sold, so a herdsman sell rule for animals with any disease sells
none, and in mark mode marks none. The Cull button is only for animals showing symptoms; to remove a
carrier, sell it.

> **Multiplayer note:** on a client, a cure - like any other disease change - shows moments after
> the server's daily update, when the pen syncs. The server always has the correct state.

---

## When a Disease Raises Output

Most disease effects lower production, but these raise an output instead:

- **PED** drastically increases a pig's liquid manure while it is sick (the diarrhoea), even as its
  solid manure drops.
- **CVM carriers.** A cow that carries CVM gives considerably more milk than a non-carrier, for
  life, while the **Diseases** setting is on. The carrier is not sick and keeps its full value.
  Whether that is worth the breeding risk is covered under [CVM](#cvm-complex-vertebral-malformation).

---

## Culling and Selling a Sick Animal

### Selling

An animal showing symptoms cannot be sold at the dealer or delivered to a butcher - by you or by
the herdsman. You can still move it between your own pens and load it onto or off a livestock
trailer, and a livestock trailer sold with animals aboard still pays for all of them, sick ones
included, as part of the trailer's price. Animals in the hidden phase, recovered animals and CVM
carriers can be sold normally.

### Value

A disease lowers an animal's value only while it shows symptoms, and several diseases at once
compound. Animals in the hidden phase, recovered animals and CVM carriers carry no disease
discount - though a young animal whose growth a disease slowed can stay slightly cheaper afterwards,
because it is lighter.

### Culling

The **Diseases** dialog has a **Cull** button for an animal in a pen that shows symptoms - never for
an animal that is only a carrier, is immune, or is still in the hidden phase. Culling asks for
confirmation first. A culled animal leaves the pen at once and stops spreading the disease from the
next day. It pays a third (33%) of the animal's current sale price, which the disease has already
lowered; a chicken pays nothing. Culling works whether **Animal Death** is on or off. An animal on a
trailer has to be unloaded into a pen first.

---

## Mastitis

**Affects:** Cows and goats that are currently lactating

Mastitis is an udder infection that stops milk production. Only an animal that is currently lactating can catch it, so a cow or goat that is not lactating is safe - and sheep, which never lactate, never catch it.

| Parameter | Value |
|-----------|-------|
| Spread | Slow |
| Fatality (untreated) | Low - it rarely kills |
| Treatment | 1 month, $200 |
| Natural recovery | At least 2 months without treatment, sometimes longer |
| Immunity after recovery | 12 months |

### Impact on Production

| Impact | Effect |
|--------|--------|
| Milk / Goat milk | **Completely stopped** |
| Growth | Slightly slower |
| Chance to conceive | Noticeably lower |
| Value while sick | Small reduction |

### Management Tips

- Treat at once ($200): the course takes 1 month, while an untreated animal stays dry for at least 2 months
- After recovery, the animal is immune for 12 months
- Only a lactating animal can catch it, so your milking herd is where it shows up
- In a large dairy herd, keep treatment funds available - cases come regularly

---

## CVM (Complex Vertebral Malformation)

**Affects:** Cattle (genetic - never caught, never spread)

CVM is a recessive genetic disease. It is never caught and never spreads: a calf inherits it from its parents at conception, and a few dealer cattle carry it. An animal with one copy of the gene is a **carrier** - healthy for life, never sick from CVM, and, for a cow, a considerably better milk producer while the **Diseases** setting is on. An animal with two copies is **affected** - sick from birth and untreatable, and with **Animal Death** on it dies within a few months. CVM posts no "Contracted" message.

| Parameter | Value |
|-----------|-------|
| Spread | None - inherited only |
| Fatality | Affected animals: almost always, within a few months (with **Animal Death** on) |
| Treatment | None |
| Natural recovery | Never |
| From the dealer | About 1 in 200 dealer cattle carry the gene - most as carriers, a few affected |

### Impact on Production

| Impact | Effect |
|--------|--------|
| Milk (carrier cow) | **Considerably increased** |
| Affected animal | No change to production - but sick for life |
| Value while sick | Moderate reduction (affected animals only; carriers keep their full value) |

### Management Tips

- Check new cattle: a carrier shows the grey DNA icon on its card, and CVM is listed in its detail panel
- Carrier cows are good milk producers - breed them with non-carriers and no calf is affected
- Two carriers bred together give about a quarter affected calves
- An affected animal cannot be treated, and you cannot sell it at the dealer; cull it from the Diseases dialog

### Carrier cows: the trade-off

What a calf inherits is settled at conception, from both parents' genes:

| Parents | Calves |
|---------|--------|
| Non-carrier x non-carrier | All non-carriers |
| Carrier x non-carrier | 50% carriers, 50% non-carriers (all healthy) |
| Carrier x carrier | 25% non-carriers, 50% carriers, 25% affected |

At conception an affected parent passes the gene to every calf: with a non-carrier every calf is a carrier, and with a carrier half the calves are affected. Artificial insemination, or a conception with no live bull, counts the cow's genes only - a carrier cow then gives 50% carriers and 50% non-carriers. Inheritance and dealer stock carrying the gene both depend on the disease settings - see [Disease Settings](#disease-settings).

---

## Foot and Mouth

**Affects:** Cows, sheep, goats, pigs

Foot and Mouth spreads fast and affects more kinds of animal than any other disease. Any animal from one month old can catch it on its own. Treatment cures it, and an untreated animal recovers on its own after at least 2 months unless it dies first.

| Parameter | Value |
|-----------|-------|
| Spread | Fast |
| Fatality (untreated) | Low to moderate |
| Treatment | 1 month, $250 |
| Natural recovery | At least 2 months without treatment, sometimes longer |
| Immunity after recovery | 24 months |

### Impact on Production

| Impact | Effect |
|--------|--------|
| Milk (cow) | **Severely reduced** |
| Wool / Goat milk | Slightly reduced |
| Growth | Noticeably slower |
| Chance to conceive | Considerably lower |
| Value while sick | **Major reduction** |

### Management Tips

- Treat every case as soon as it shows ($250 for the 1-month course) - it spreads fast
- On **Easy** and **Normal**, move a new case into an empty pen the day it shows; on **Hard** and **Very hard** it has often spread already
- Milk drops severely - an outbreak in a dairy herd is expensive
- A sick animal cannot be sold at the dealer, and its value - which sets what culling pays - is greatly reduced while it is sick
- After recovery, the animal is immune for 24 months

---

## Porcine Epidemic Diarrhoea (PED)

**Affects:** Pigs

PED is a diarrhoeal disease that hits young piglets hardest. Newborn piglets in their first month catch it most often, then piglets up to 6 months old; older pigs rarely catch it on their own, though any pig can catch it from a sick pen mate. It is also at its most dangerous in young piglets.

| Parameter | Value |
|-----------|-------|
| Spread | Moderate |
| Fatality (untreated) | Moderate - worst in young piglets |
| Treatment | 1 month, $150 |
| Natural recovery | At least 2 months without treatment, sometimes longer |
| Immunity after recovery | 12 months |

### Impact on Production

| Impact | Effect |
|--------|--------|
| Liquid manure | **Drastically increased** (diarrhoea) |
| Manure | Severely reduced |
| Growth | Considerably slower |
| Value while sick | Major reduction |

### Management Tips

- Treatment is cheap ($150) and takes 1 month - treat every case at once, piglets first
- An untreated pig stays sick for at least 2 months, and every sick day carries a risk
- Watch pens with newborn piglets: they catch it most often
- If PED keeps recurring, consider a lower **Diseases** level

---

## Avian Flu (LPAI)

**Affects:** Chickens

LPAI is short for low-pathogenic avian influenza - the common, milder strain. Birds of any age can catch it, it spreads through a pen at a moderate pace, and treatment is cheap. See [Telling the two apart](#telling-the-two-apart).

| Parameter | Value |
|-----------|-------|
| Spread | Moderate |
| Fatality (untreated) | Low |
| Treatment | 1 month, $5 |
| Natural recovery | At least 2 months without treatment, sometimes longer |
| Immunity after recovery | 12 months |

### Impact on Production

| Impact | Effect |
|--------|--------|
| Eggs | Drop to about 40% of normal while a bird is sick |
| Growth | Slightly slower |
| Value while sick | Severe reduction |

### Management Tips

- Treat sick birds - at $5 a course, treatment costs almost nothing
- Look for sick birds in the animal list and the Diseases dialog, not in egg counts - one hen's drop barely shows in a pen's production
- Survivors are immune for 12 months

---

## Avian Flu (HPAI)

**Affects:** Chickens

HPAI is short for high-pathogenic avian influenza - the rare, deadly strain. It shows at once on every **Diseases** level, spreads fast and has no treatment: while **Animal Death** is on, a sick bird rarely survives it. The defence is to cull a sick bird the day it shows: an HPAI case first spreads the day after it shows, so a bird culled that day infects nobody. Nothing in the game prompts the cull, so act on the "Contracted" message the day it posts.

| Parameter | Value |
|-----------|-------|
| Spread | Fast |
| Fatality (untreated) | Almost always fatal, within days |
| Treatment | **None** - cull |
| Natural recovery | Rare while **Animal Death** is on |
| Immunity after recovery | 24 months |

### Impact on Production

| Impact | Effect |
|--------|--------|
| Eggs | No change - a sick hen keeps laying |
| Value while sick | Severe reduction |

### Management Tips

- Cull every HPAI case from the Diseases dialog on the day it shows (a culled chicken pays nothing)
- A sick bird cannot be sold at the dealer
- Left alone, one case spreads fast through the rest of the pen
- A bird that survives is immune for 24 months

### Telling the two apart

The disease name in the detail panel and the Diseases dialog says which strain a bird has:

| | Avian Flu (LPAI) | Avian Flu (HPAI) |
|---|---|---|
| How common | Common | Rare |
| Spread | Moderate | Fast |
| Danger | Low - most birds recover | Almost always fatal |
| Treatment | 1 month, $5 | None - cull |
| Eggs while sick | About 40% of normal | Unchanged |
| Symptoms | After a short hidden phase on **Hard** and **Very hard** | At once, on every level |

---

## BRD (Bovine Respiratory Disease)

**Affects:** Cattle

BRD is a respiratory disease that hits calves hardest. Calves up to 6 months old catch it most often, then young stock up to 2 years; older cattle catch it less often. It spreads through a pen at a moderate pace and is at its most dangerous in calves.

| Parameter | Value |
|-----------|-------|
| Spread | Moderate |
| Fatality (untreated) | Moderate - worst in calves |
| Treatment | 1 month, $300 |
| Natural recovery | At least 2 months without treatment, sometimes longer |
| Immunity after recovery | 12 months |

### Impact on Production

| Impact | Effect |
|--------|--------|
| Milk | Noticeably reduced |
| Manure | Noticeably reduced |
| Growth | Noticeably slower |
| Value while sick | Moderate reduction |

### Management Tips

- Treat every case at once ($300) - calves are the ones most likely to die of it
- Watch your calf pens: calves up to 6 months old catch it most often
- After recovery, the animal is immune for 12 months

---

## Pulpy Kidney

**Affects:** Sheep, goats

Pulpy kidney never spreads between animals - every case starts on its own. Lambs and kids up to 12 months old catch it more often than older animals, and they are the most at risk from it. It is the deadliest disease a sheep or goat can catch, and treatment cures only about half the time.

| Parameter | Value |
|-----------|-------|
| Spread | None - never passes between animals |
| Fatality (untreated) | High - worst in lambs and kids |
| Treatment | 1 month, $150, which cures about half the time |
| Natural recovery | At least 2 months without treatment, sometimes longer |
| Immunity after recovery | 12 months |

### Impact on Production

| Impact | Effect |
|--------|--------|
| Wool / Goat milk | Considerably reduced |
| Growth | Considerably slower |
| Value while sick | Major reduction |

### Management Tips

- Start treatment the day it shows
- A failed course is worth following with another - a message tells you when a course ends without a cure
- After recovery, the animal is immune for 12 months

---

## Colic

**Affects:** Horses

Colic is a painful digestive condition. It never passes between horses - every case starts on its own - and it shows at once. Foals up to 11 months old catch it less often than older horses, but a young horse that has it is more at risk. Treatment cures only about half the time: it lowers the risk without removing it, and on a low-value horse a course can cost more than the risk it removes is worth.

| Parameter | Value |
|-----------|-------|
| Spread | None - never passes between horses |
| Fatality (untreated) | Moderate |
| Treatment | 1 month, $500, which cures about half the time |
| Natural recovery | At least 2 months without treatment, sometimes longer |
| Immunity after recovery | 6 months |

### Impact on Production

| Impact | Effect |
|--------|--------|
| Manure | Considerably reduced |
| Growth | Noticeably slower in a horse that is still growing |
| Value while sick | Major reduction |

### Management Tips

- On a valuable horse, start treatment as soon as colic shows - a treated horse dies less often than an untreated one
- If a course does not cure a valuable horse, start another - each course is a fresh chance
- A sick horse cannot be sold at the dealer until it recovers
- After recovery, the horse cannot get colic again for 6 months

---

## Disease Settings

These settings decide how diseases play. The Settings Reference has their full text, under [Diseases](reference-settings.md#diseases) and [Death & Accidents](reference-settings.md#death-accidents).

### Diseases

Sets the level - **Off**, **Easy**, **Normal** (the default), **Hard** or **Very hard**. What each level changes is under [Difficulty Levels](#difficulty-levels). Admin only in multiplayer.

*Choosing **Off** stops new infections and all disease progression, spread, and effects, and no calf inherits CVM and no dealer animal is stocked carrying it. Animals already infected are not cured - their diseases resume where they stopped when a level is chosen again - and existing diseases are hidden and a CVM carrier's extra milk stops while the setting is **Off**. While it is **Off**, a sick animal reads as healthy, so nothing stops it being sold and it cannot be culled.*

### Choose Diseases

Directly below the **Diseases** row. Untick a disease and no new case of it starts, and it stops spreading - even from animals already ill with it. Existing cases carry on: an animal already ill with it still recovers or dies as usual, treatment still works, and a CVM carrier keeps its extra milk. An animal already in the hidden phase still falls ill and gets the "Contracted" message; the Settings Reference lists every case that keeps a switched-off disease. For CVM, unticking it also means no dealer animal stocked from then on carries it and no calf conceived from then on inherits it. While **Diseases** is **Off**, no disease starts whatever is ticked. Admin only in multiplayer.

### Animal Death

**Animal Death** (the ModHub build labels it "Animal Removal") decides whether animals can die - of old age, low health, accidents, birth complications and diseases. With it off, no animal dies of a disease: every disease but CVM ends in recovery - Avian Flu (HPAI) included - and an animal affected by CVM stays sick for life. Diseases still spread, cut production and lower value, and culling still works.
