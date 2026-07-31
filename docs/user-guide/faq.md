# Frequently Asked Questions

Common questions about Realistic Livestock RM, covering genetics, breeding, and mod scope.

> **Note:** This documentation was generated with AI assistance and may contain inaccuracies. If you spot an error, please [open an issue](https://github.com/rittermod/FS25_RealisticLivestockRM/issues).

---

## How can offspring have worse genetics than their parents?

**Short answer:** Breeding two high-genetics animals improves your odds of good offspring, but it doesn't guarantee every single one will match the parents. Some calves will be better, some will be worse - that's how real genetics works, and the mod simulates this.

### What changed from the original mod

Arrow-kb's original version used a simple model where offspring were randomly placed somewhere between the two parents' values. No variation beyond that range, no chance of outperforming the parents, and no regression. It was predictable but unrealistic.

The current version uses a more realistic genetic model: the offspring's trait value is based on the **average of both parents** plus some **random variation**. This means offspring can exceed both parents - or fall below both.

### Why it happens

Each parent carries a mix of "good" and "not so good" genes. A high-producing cow doesn't only carry great genes - she also carries some weaker ones that aren't visible in her own stats. When two parents each pass a random half of their genes to the calf, the calf might inherit an unlucky combination and end up worse than either parent.

### What the mod does

The mod calculates the average of both parents' trait values (the "mid-parent value"), then adds random variation using a bell curve. Most offspring land near that average, but some land higher and some lower - with roughly equal probability in both directions.

```mermaid
%%{init: {"themeVariables": {"xyChart": {"plotColorPalette": "#1565c0"}}}}%%
xychart-beta
    title "Offspring Trait Distribution Around Mid-Parent Value"
    x-axis "Trait Value (relative to mid-parent)" ["Much Lower", "Lower", "Slightly Lower", "Mid-Parent", "Slightly Higher", "Higher", "Much Higher"]
    y-axis "Likelihood" 0 --> 100
    bar [3, 12, 28, 100, 28, 12, 3]
```

*Most offspring cluster around the mid-parent average. A few will be noticeably better or worse. Extreme outliers in either direction are rare but possible.*

### Regression to the mean

This is a well-known phenomenon in genetics called **regression to the mean**, first discovered by Francis Galton in the 1880s. He noticed that children of very tall parents were tall, but usually not quite as tall as their parents. The same goes the other way - children of short parents tend to be a bit taller than their parents.

In the mod, breeding two "Extremely High" productivity cows will produce calves that are above average - but many of them will be "Very High" rather than "Extremely High." The parents were statistical outliers, and their offspring tend to drift back towards the population average.

### Where you'll notice it first

Chickens cycle through generations much faster than other animals (2-month hatching vs 10-month cattle gestation), so genetic drift shows up in your chicken flock first. If you're seeing unexpected drops in egg production across generations, this is likely why.

### The good news - but it takes work

Over many generations, consistently breeding your best animals **does** improve the herd average. But "consistently" is the key word - you have to actively manage who breeds with who. If you let a herd stay together through multiple generations without culling, lower-genetics offspring will breed with each other and the herd average will drift towards the mean over time.

To maintain a top-tier herd:

- **Cull low-genetics animals** from your breeding stock - sell or castrate them
- **Only let your best breed with your best** - don't leave it to chance
- **Check offspring genetics** each generation and remove underperformers

This is more work than the old model, but it's what real livestock farmers do - and it makes the breeding game genuinely interesting as a long-term strategy rather than a one-time setup.

See the [Genetics Guide](guide-genetics.md#breeding-inheritance) for practical breeding strategies.

### Further reading

For the curious, here's the real science behind the simulation:

- [Regression to the Mean](https://select-statistics.co.uk/blog/regression-to-the-mean-as-relevant-today-as-it-was-in-the-1900s/) - Select Statistics - accessible explanation of Galton's original discovery
- [The Infinitesimal Model](https://en.wikipedia.org/wiki/Infinitesimal_model) - Wikipedia - the formal genetics model behind the simulation
- [Mendel's Law of Segregation](https://www.khanacademy.org/science/ap-biology/heredity/mendelian-genetics-ap/a/the-law-of-segregation) - Khan Academy - why gene inheritance is random
- [Estimating Trait Heritability](https://www.nature.com/scitable/topicpage/estimating-trait-heritability-46889/) - Nature - how heritability works in real livestock breeding

---

## What breed will my cross-bred offspring be?

**Short answer:** Each offspring independently has a 50/50 chance of being either parent's breed. There's no visual blending - the calf, piglet, or lamb will look exactly like one parent's breed or the other.

### How it works

When a male and female of different breeds produce offspring, the mod flips a coin for each baby:

```mermaid
flowchart TD
    A["Offspring born"] --> B{"Artificial\ninsemination?"}
    B -->|Yes| C["Always mother's breed"]
    B -->|No| D{"Coin flip\n(per offspring)"}
    D -->|50%| E["Father's breed"]
    D -->|50%| F["Mother's breed"]
```

Each offspring in a litter or set of twins rolls independently, so siblings from the same birth can be different breeds. A Berkshire sow bred by a Landrace boar might produce a litter with a mix of Berkshire and Landrace piglets.

### Artificial insemination is different

When using artificial insemination (AI), offspring **always** inherit the mother's breed. The AI system doesn't carry breed-specific sire information, so there's no coin flip - it defaults to the mother's breed every time.

If you want all offspring to match a specific breed, AI gives you that control.

### Breed is not the same as genetics

This is the most common point of confusion. Breed determines **appearance** - what the animal looks like. Genetics determine **traits** - productivity, health, fertility, quality, and metabolism.

When cross-breeding:

- **Breed:** One parent or the other (coin flip)
- **Genetic traits:** Always a blend of both parents

So an Angus calf born from an Angus bull x Holstein cow pairing will *look* Angus, but its milk productivity, health genetics, and other traits are still influenced by the Holstein mother. The breed coin flip doesn't affect genetic inheritance at all.

### What about breed-locked animals?

Water Buffalo and Goats can only breed within their own breed (see [Breed Restrictions](guide-breeding.md#breed-restrictions)), so the question of offspring breed doesn't arise - both parents are always the same breed.

### Quick reference

| Scenario | Offspring Breed |
|----------|----------------|
| Same-breed parents | Always that breed |
| Different breeds, natural mating | 50% chance of either breed (per offspring) |
| Different breeds, AI | Always mother's breed |
| Breed-locked types | Always same breed (can only breed within breed) |

See the [Breeding Guide](guide-breeding.md#offspring-breed) for examples and practical tips.

---

## Does the mod work on my map?

Almost certainly yes. RLRM works on virtually any map - it does not need to be on a supported list. The maps listed in the docs are only the ones that add their *own* custom animal types or breeds, which need built-in support so those extras also get genetics and breeding. On any other map, the standard FS25 animals work normally.

(Rare exception: a map that heavily replaces the animal husbandry setup could clash - if something looks off, [open an issue](https://github.com/rittermod/FS25_RealisticLivestockRM/issues).)

---

## Can you add more breeds or animal types?

**Short answer:** Yes - the mod supports **[Animal Packs](guide-animal-packs.md)**, third-party mods that can add new breeds or adjust animal balance. Modders can create packs that range from simple balance tweaks to full breed additions with custom visuals.

### Animal Packs

Animal packs are the recommended way to add breeds or customise animal properties. A pack is a standard FS25 mod that RLRM discovers and loads automatically - just enable it alongside the main mod. No manual XML editing required.

Packs can:

- **Add new breeds** with custom 3D models, textures, and store images
- **Adjust balance** on existing breeds - prices, food consumption, production rates, reproduction timing

See [Animal Packs](guide-animal-packs.md) for how to install and use them, or [Creating Animal Packs](guide-creating-packs.md) if you're a modder interested in making your own.

### Why the mod doesn't include new breeds itself

Creating animal breeds requires 3D models, textures, and animations - a completely different skill set from the scripting and game mechanics this mod focuses on. The mod works with whatever breeds the base game and DLCs provide (currently 7 cattle breeds, 3 pig breeds, 5 sheep/goat breeds, 8 horse colour variants, and chickens).

Each breed in Realistic Livestock has detailed configuration: food consumption curves by age, production rates at different life stages, target weights, sell prices, breeding parameters, and more. Adding a breed properly is a two-part job:

1. **The 3D model** - visual appearance, textures, animations (modelling skill)
2. **The simulation data** - realistic food, production, pricing, and breeding curves (XML configuration)

Ritter can do part 2 but not part 1. The animal pack system makes it possible for modellers to handle part 1 while RLRM handles the integration.

### Map-based animals

When a map includes its own animal types or breeds, the mod can add built-in support with full breeding and reproduction. **[Hof Bergmann](map-hof-bergmann.md)** adds exotic animal *species* (ducks, geese, cats, rabbits, alpacas, quail). **[Witcombe](map-witcombe.md)** instead adds new *breeds* within the standard cow, pig, sheep, and rabbit types (Jersey, Gloucestershire Old Spot, Texel, Suffolk, Blue Faced Leicester) - and corrects Hereford on the map with a heritage profile.

The mod uses **version-aware map support**. It detects which version of a supported map you have installed and loads the matching configuration automatically. This means:

- **Tested version** - Everything works seamlessly. No action needed.
- **Untested version** (e.g., the map author released an update before the mod was updated) - You'll see a warning dialog when the game starts. The warning includes a link to report problems so support can be added for the new version.

If you're playing a map with custom animals that aren't supported yet, [open an issue](https://github.com/rittermod/FS25_RealisticLivestockRM/issues) and it can be considered.

### Legacy: Custom Animals setting

Before the pack system existed, the only way to add breeds was by manually merging XML files and loading them through the [Custom Animals](reference-settings.md#custom-animals) setting. This approach still works for singleplayer but has limitations - it requires manual XML editing, doesn't work in multiplayer, and replaces all animal definitions rather than layering on top.

If you previously used this method, consider migrating to an animal pack instead.

Don't confuse this with **Choose Animals For Sale**, which is a separate mechanism and neither replaces the other. Custom Animals swaps the whole animal definition file; the selector only decides which of the breeds you already have get stocked by the dealer.

### A note on unauthorized breed packs

Some breed packs floating around online are stolen copies of other mods with minor texture swaps. These are not supported and may cause conflicts. Stick to breed packs from known sources like the official [Farming Simulator mod hub](https://www.farming-simulator.com/mods.php?title=fs2025).

---

## How do I stop the dealer offering a breed or age group?

**Short answer:** RL Menu -> **Settings** -> **Choose Animals For Sale**. Untick whatever you don't want, press **OK**, and the dealer restocks without it.

The selector is grouped into sections - **one per breed and sex**, so "Holstein" and "Holstein Bull" are two separate sections. Each section lists one row per age group, labelled in months. Holstein cows, for example, show four: `0-5 months`, `6-11 months`, `12-17 months` and `18-72 months`. How many groups an animal has, and where they split, varies. A row is ticked when the dealer currently offers that group: on a clean install everything starts ticked, and once you start making changes the ticks reflect your own choices.

Handy while you are in there: the **Select All / Select None** button applies to the section you are currently on, not the whole list, and you can toggle the highlighted row with **A**.

A few things worth knowing:

- **It only affects new dealer stock.** Animals you already own are untouched, keep producing, and keep breeding normally. Nothing is deleted, and artificial insemination is unaffected.
- **OK restocks the WHOLE dealer.** Not just what you changed - every animal type is re-rolled, exactly as if you had pressed Reset Animal Dealer, so your pig, sheep, horse and chicken stock is replaced too. **Back** discards your changes. Pressing OK without having actually changed anything leaves the stock alone - as does re-making a change another admin already made.
- **Tick it back to undo.** Setting a row back to the value it originally shipped with stops overriding it, so a later mod update to that default will be followed again.
- **It is saved with your game**, and in multiplayer it is server-wide and admin-only - other players see the setting but cannot change it.
- **Pack breeds work the same way.** Breeds added by an [animal pack](guide-animal-packs.md) appear in the selector alongside the built-in ones, and pack breeds may ship with some age groups already switched off. A row you unticked is remembered even if you remove the pack and add it back - as long as the pack still uses the same age groups. If a pack update shifts its age groups, the old entry is orphaned.

Hiding every age group in a section removes that section's animals from the dealer. Remember the sex split: to drop a breed completely, untick every group in **both** of its sections. Hiding every buyable animal of a type leaves that type's dealer list empty - which is allowed, if that is what you want.

---

## Why are the dealer's animals so poor - or so expensive?

**Short answer:** RL Menu -> **Settings** -> **Dealer Animal Quality**. One setting decides both how good the dealer's stock is and what it costs.

- **Budget** - the dealer stocks weaker animals and asks barely more than they are worth. Cheap to buy from, slow to build a strong herd from.
- **Standard** - the default, and exactly how the mod behaves without touching the setting: the full natural spread of animals at the usual dealer price.
- **Premium** - the dealer stocks strong animals only, and charges a steep premium for them.

A few things worth knowing:

- **Roughly one animal in thirteen ignores the setting**, in either direction. A Budget dealer can be hiding a genuinely good animal, and a Premium one can offer something ordinary at a premium price. That is deliberate - it keeps it worth actually reading the list.
- **Changing the setting restocks the dealer.** An animal's genetics are fixed when it is generated, so existing stock cannot be re-graded - it is replaced. Animals you already own are untouched, and the AI animals used for insemination are not affected at all.
- **The herdsman pays the same price you do.** If you have it buying animals for you, it budgets at the active setting's markup.
- **In multiplayer it is server-wide and admin-only** - other players see the setting but cannot change it.

Don't confuse this with **Genetics Display**, which only changes whether genetics numbers are shown in animal names. It has no effect on what the dealer offers.

---

## Why don't Hof Bergmann pasture bulls breed like cattle?

**Short answer:** Hof Bergmann's pasture bulls are a completely different animal type from cattle. The game engine doesn't allow animals of different types to breed with each other, and this isn't something the mod can work around.

### The technical reason

In FS25, every animal belongs to an **animal type** - COW, PIG, SHEEP, CHICKEN, and so on. Breeding only works between animals of the same type. RLRM's cattle bulls (Holstein Bull, Angus Bull, etc.) are all subtypes of the **COW** type, which is why they can breed with cows.

Hof Bergmann adds a separate **BULL** animal type for its decorative pasture bulls. As far as the game engine is concerned, a BULL-type animal and a COW-type animal are as different as a cow and a chicken. They have separate husbandries, separate slot systems, and no mechanism to interact.

```mermaid
flowchart LR
    subgraph COW["COW Type (shared husbandry)"]
        direction TB
        HC["Holstein Cow"] ---|"can breed"| HB["Holstein Bull"]
        AC["Angus Cow"] ---|"can breed"| AB["Angus Bull"]
        HC --- AB
        AC --- HB

    end
    subgraph BULL["BULL Type (separate husbandry)"]
        PB["Pasture Bull"]
    end
    COW -.-x|"different types\ncannot interact"| BULL
```

### Why it can't be fixed in the mod

There are two theoretical approaches, neither of which is practical:

1. **Merge HB's BULL into the COW type** - This would require changing how the map assigns animals to husbandry buildings, pastures, and slot systems. That's a map-level change, not something a script mod can do.

2. **Cross-type breeding** - Letting animals of different types breed with each other would require a fundamentally new system in the game engine. FS25 simply doesn't support it.

### "Can't you just use the pasture bull models?"

This is a natural question. The base game doesn't include separate bull 3D models - RLRM's breeding bulls (Holstein Bull, Angus Bull, etc.) reuse the female cow models, so visually they look the same as cows. Meanwhile, HB's pasture bulls have their own distinct bull visuals, which is exactly what you'd want on your breeding bulls.

Unfortunately, each animal type loads its own set of 3D models from the map's configuration - the COW type has one model pool, the BULL type has a completely separate one. To use HB's bull models on COW-type animals, you'd have to rebuild the map's entire animal model loading infrastructure from a script mod and apply it on top. This is extremely brittle: any map update can shift model indices, causing wrong or missing visuals. It's not a reliable approach for a mod that needs to work across map versions.

### What you still get

The pasture bull still gets the full RLRM individual tracking treatment - it has a unique name, genetics, and identity. It just can't participate in the cattle breeding cycle.

If you want bulls that breed with your cows, use the cattle bulls available in the cow husbandry (Holstein Bull, Angus Bull, etc.) - those are COW-type animals and work normally with the breeding system.

For the full picture of what Hof Bergmann support includes, see [Hof Bergmann Map Support](map-hof-bergmann.md).

## Why doesn't the Hof Bergmann bull stable produce sperm under RLRM?

Hof Bergmann models bull sperm (BULLSPERM) as a milk output on the dedicated BULL animal type. In vanilla FS25 this works because the husbandry building generates milk from cluster-level production, regardless of subtype gender. RLRM replaces that pipeline with per-animal output that only produces milk for lactating female cows that have given birth within the last 10 months. The BULL animal type is a separate species from COW (see the previous question), so its animals never qualify and the bull stable's BULLSPERM trigger stays empty.

There is no mod-side fix that wouldn't have side effects on every other animal type, so this is a documented incompatibility rather than a patched one. With RLRM active the HB pasture bulls and their stable are essentially decorative: the animals still get individual tracking, genetics, and visuals, but the bull stable doesn't yield sperm for artificial insemination workflows that depend on it.

See [Hof Bergmann Map Support](map-hof-bergmann.md#pasture-bulls-are-not-cattle) for the full set of HB-under-RLRM caveats.
