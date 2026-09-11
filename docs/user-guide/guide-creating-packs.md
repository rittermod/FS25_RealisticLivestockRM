# Creating Animal Packs

Technical reference for modders who want to create animal packs for Realistic Livestock RM. An animal pack is a standard FS25 mod that RLRM discovers and loads automatically -- no registration or code changes needed.

> **Note:** This documentation was generated with AI assistance and may contain inaccuracies. If you spot an error, please [open an issue](https://github.com/rittermod/FS25_RealisticLivestockRM/issues).

---

## Overview

An animal pack is any FS25 mod that contains an `rlrm_pack.xml` file in its root directory. When RLRM starts, it scans all enabled mods for this file. If found, the mod is treated as a pack and its resources are loaded on top of RLRM's base animal definitions.

Packs can do two things:

1. **Override properties** on existing breeds -- change prices, food consumption, production rates, reproduction parameters, weights, and more
2. **Add new breeds** -- define entirely new subtypes with custom visuals, fill types, and translations

You can do either or both in a single pack.

---

## Pack Types

### Balance Pack (property overrides only)

The simplest kind of pack. It changes values on existing breeds without adding any new ones. No models, no textures, no fill types -- just an XML file with the properties you want to change.

```
FS25_RLRM_MyBalance/
├── modDesc.xml
├── rlrm_pack.xml
└── animals.xml
```

Use this when you want to adjust prices, food curves, reproduction timing, or other simulation parameters to your preference.

### Breed Pack (new breeds with visuals)

A more complex pack that adds entirely new breeds. This typically requires custom model configurations, store images, fill types, and translations.

```
FS25_RLRM_MyCowBreeds/
├── modDesc.xml
├── rlrm_pack.xml
├── animals.xml
├── fillTypes.xml
├── translations/
│   ├── translation_en.xml
│   └── translation_de.xml
├── images/
│   ├── store_myBreed.dds
│   └── store_myBreedBaby.dds
└── models/
    └── cow/
        └── animals.xml          (model config with texture atlases)
```

---

## Pack Descriptor

Every pack must have an `rlrm_pack.xml` in its mod root. This file tells RLRM what resources the pack provides.

```xml
<?xml version="1.0" encoding="utf-8" standalone="no" ?>
<rlrmPack name="My Pack Name" author="Your Name" version="1.0">
    <!-- Path to animal definitions (overrides and/or new subtypes) -->
    <animals path="animals.xml"/>

    <!-- Path to fill type definitions (only needed when adding new breeds) -->
    <fillTypes path="fillTypes.xml"/>

    <!-- Prefix for translation files (only needed for new breed names, fill type titles, etc.) -->
    <translations prefix="translations/translation"/>
</rlrmPack>
```

All paths are relative to the mod's root directory. Omit any element you don't need -- a balance pack typically only needs `<animals>`.

### Descriptor attributes

| Attribute | Required | Description |
|-----------|----------|-------------|
| `name` | No | Display name shown in the game log. Defaults to the mod name. |
| `author` | No | Pack author, shown in the game log. |
| `version` | No | Pack version, shown in the game log. |

### Resource elements

| Element | Required | Description |
|---------|----------|-------------|
| `<animals path="..."/>` | No | Animal definitions file -- property overrides and/or new subtypes |
| `<fillTypes path="..."/>` | No | Fill type definitions -- needed when adding new breeds |
| `<translations prefix="..."/>` | No | Translation file prefix -- for localized breed names and fill type titles |

---

## Animal Definitions

The `animals.xml` file is where the main work happens. It can contain:

- [Property overrides](#property-overrides) for existing breeds
- [New subtype definitions](#adding-new-subtypes) for new breeds
- [Config overrides](#config-overrides) for model replacement
- [Breed metadata](#breed-metadata) for display names and marker colours
- [Breeding groups](#breeding-groups) for breeding restrictions

### Property Overrides

Override specific properties on existing breeds. Only the properties you specify are changed -- everything else keeps RLRM's default values.

```xml
<animals>
    <animal type="COW">
        <!-- Override Holstein cow prices and food consumption -->
        <subType subType="COW_HOLSTEIN">
            <buyPrice>
                <key ageMonth="0" value="300"/>
                <key ageMonth="24" value="3000"/>
            </buyPrice>
            <sellPrice>
                <key ageMonth="0" value="250"/>
                <key ageMonth="24" value="2800"/>
                <key ageMonth="36" value="3200"/>
                <key ageMonth="60" value="2000"/>
            </sellPrice>
            <input>
                <food>
                    <key ageMonth="0" value="80"/>
                    <key ageMonth="12" value="300"/>
                    <key ageMonth="18" value="420"/>
                </food>
            </input>
        </subType>

        <!-- Override pig reproduction timing -->
    </animal>

    <animal type="PIG">
        <subType subType="PIG_LANDRACE">
            <reproduction minAgeMonth="6" durationMonth="4" minHealthFactor="0.8"/>
        </subType>
    </animal>
</animals>
```

#### Overridable subtype properties

| Property | XML | Format |
|----------|-----|--------|
| Gender | `subType#gender` | `"female"` or `"male"` |
| Breed | `subType#breed` | Breed name string (uppercase) |
| Birth weight | `subType#minWeight` | kg (float) |
| Target weight | `subType#targetWeight` | kg (float) |
| Maximum weight | `subType#maxWeight` | kg (float) |
| Reproduction | `<reproduction>` | `supported`, `minAgeMonth`, `durationMonth`, `minHealthFactor` |
| Health rates | `<health>` | `increasePerHour`, `decreasePerHour` (0-100) |
| Buy price curve | `<buyPrice>` | AnimCurve: `<key ageMonth="X" value="Y"/>` |
| Sell price curve | `<sellPrice>` | AnimCurve |
| Transport price curve | `<transportPrice>` | AnimCurve |
| Food consumption | `<input><food>` | AnimCurve |
| Water consumption | `<input><water>` | AnimCurve |
| Straw consumption | `<input><straw>` | AnimCurve |
| Manure output | `<output><manure>` | AnimCurve |
| Liquid manure output | `<output><liquidManure>` | AnimCurve |
| Milk output | `<output><milk fillType="MILK">` | AnimCurve (with fill type) |
| Pallet output | `<output><pallets fillType="...">` | AnimCurve (with fill type) |
| Visual stages | `<visuals><visual>` | Override or insert by `minAge` match (see [Visual Overrides](#visual-overrides)) |
| Rideable vehicle | `<rideable filename="..."/>` | Horse rideable vehicle XML, path relative to the pack root |

#### Overridable type-level properties

These are set on the `<animal type="...">` element and affect all breeds of that type:

| Property | XML | Format |
|----------|-----|--------|
| Pregnancy | `<pregnancy average="2" max="6"/>` | Average and max offspring count |
| Fertility curve | `<fertility>` | AnimCurve: breeding probability by age |
| Average buy age | `animal#averageBuyAge` | Months (integer) |
| Maximum buy age | `animal#maxBuyAge` | Months (integer) |
| Pasture space | `<pasture sqmPerAnimal="X"/>` | Square metres per animal (float) |

#### AnimCurve format

Price, production, and consumption curves use age-based keyframes. The game linearly interpolates between keyframes.

Consumption curves (`<input>`: food, water, straw) accept decimal values such as `0.2`. Every other curve reads whole numbers only - a decimal there is cut down to its whole part (`2.9` becomes `2`).

```xml
<buyPrice>
    <key ageMonth="0" value="200"/>     <!-- At birth: $200 -->
    <key ageMonth="24" value="2500"/>   <!-- At 24 months: $2500 -->
</buyPrice>
```

### Adding New Subtypes

To add a new breed, define a full subtype within the appropriate animal type. New subtypes need:

- A unique `subType` name (uppercase, e.g., `COW_CHAROLAIS`)
- A matching `fillTypeName` (defined in your `fillTypes.xml`)
- Visual stages with store images
- All the properties a breed needs (prices, reproduction, weights, etc.)

```xml
<animals>
    <animal type="COW">
        <subType subType="COW_MYBREED" fillTypeName="COW_MYBREED"
                 gender="female" breed="MYBREED"
                 minWeight="40.0" targetWeight="600.0" maxWeight="1200.0">
            <visuals>
                <visual minAge="0" visualAnimalIndex="1"
                        image="images/store_myBreedBaby.dds"
                        canBeBought="true">
                    <description>$l10n_animal_descriptionCowMilk</description>
                    <description>$l10n_animal_descriptionCowFeed</description>
                </visual>
                <visual minAge="18" visualAnimalIndex="2"
                        image="images/store_myBreed.dds"
                        canBeBought="true">
                    <description>$l10n_animal_descriptionCowMilk</description>
                    <description>$l10n_animal_descriptionMature</description>
                </visual>
            </visuals>
            <reproduction minAgeMonth="12" durationMonth="10" minHealthFactor="0.75"/>
            <buyPrice>
                <key ageMonth="0" value="200"/>
                <key ageMonth="24" value="2500"/>
            </buyPrice>
            <sellPrice>
                <key ageMonth="0" value="150"/>
                <key ageMonth="36" value="2800"/>
                <key ageMonth="60" value="1800"/>
            </sellPrice>
            <input>
                <food>
                    <key ageMonth="0" value="50"/>
                    <key ageMonth="18" value="400"/>
                </food>
                <water>
                    <key ageMonth="0" value="20"/>
                    <key ageMonth="18" value="80"/>
                </water>
                <straw>
                    <key ageMonth="0" value="10"/>
                    <key ageMonth="18" value="60"/>
                </straw>
            </input>
            <output>
                <milk fillType="MILK">
                    <key ageMonth="0" value="0"/>
                    <key ageMonth="12" value="0"/>
                    <key ageMonth="12" value="200"/>
                    <key ageMonth="36" value="350"/>
                    <key ageMonth="120" value="180"/>
                </milk>
                <manure>
                    <key ageMonth="0" value="50"/>
                    <key ageMonth="36" value="400"/>
                </manure>
                <liquidManure>
                    <key ageMonth="0" value="50"/>
                    <key ageMonth="36" value="200"/>
                </liquidManure>
            </output>
        </subType>
    </animal>
</animals>
```

New subtypes are loaded through the same `loadSubTypes` path RLRM's own breeds use, so pack subtypes behave identically to built-in breeds.

### Visual Overrides

Visual stages define how an animal looks at different ages (calf, juvenile, adult). Each stage is matched by `minAge`. When overriding visuals on an existing breed:

- If a stage with the same `minAge` already exists, its properties are updated
- If no stage with that `minAge` exists, a new stage is inserted (sorted by age)

```xml
<subType subType="COW_HOLSTEIN">
    <visuals>
        <!-- Override the adult visual (minAge=18 already exists on Holstein) -->
        <visual minAge="18" image="images/store_myHolstein.dds" canBeBought="true"/>
    </visuals>
</subType>
```

Overridable visual properties: `visualAnimalIndex`, `image`, `canBeBought`, `description`.

> **`description` format asymmetry.** In an override or insert block, `description` is read as a single **attribute** (`description="$l10n_..."`), not as the `<description>` **child** elements used when defining a brand-new subtype. If you copy the child-element form into an override block, the descriptions are silently ignored.

> **`canBeBought` is a shipped default, not the final word.** The RL Menu's Settings tab has a **Choose Animals For Sale** button that lists every breed and age stage and writes the same `canBeBought` flag at runtime. A player's selection takes precedence over what your pack shipped and is saved with their game, so ship the default you think is right but do not rely on it staying that way. Clearing a selection back to your shipped value stops overriding it, so a later pack update is picked up again.

#### Texture Filtering

When multiple breeds share the same 3D model but use different texture rows from a texture atlas, use `textureIndexes` to restrict which variations a breed displays:

```xml
<visual minAge="18" visualAnimalIndex="2" image="images/store_myBreed.dds">
    <textureIndexes>
        <value>3</value>
        <value>4</value>
    </textureIndexes>
</visual>
```

This tells the engine to only use texture variations 3 and 4 from the model's variation list for this breed, rather than randomly picking from all available textures. This is essential when multiple breeds share one model config but need distinct appearances.

> **Caveat:** `textureIndexes` applies when defining a new subtype and when overriding an **existing** visual stage, but it is **ignored when an override inserts a new stage** (a new `minAge`) on an existing breed. Insert the stage first, then override it if you need texture filtering on it.

### Config Overrides

Config overrides replace the **entire model configuration** for an animal type. This is needed when your pack adds new 3D models or expanded texture atlases that aren't in the base game's model config.

```xml
<animals>
    <configOverrides>
        <override type="COW" configFilename="models/cow/animals.xml"/>
    </configOverrides>

    <!-- ... subtypes and overrides below ... -->
</animals>
```

The `configFilename` path is relative to the pack's mod directory. It points to a model config file (the same format the base game uses to define animal 3D models and their texture variations).

When a config override is applied, RLRM:

1. Replaces the model config path for that animal type
2. Reloads all model data from the new config
3. Re-links all existing subtypes' visual references to the new model objects
4. Re-applies any texture filtering (`textureIndexes`) on existing subtypes

> **Important:** Config overrides are a **total replacement** -- not additive. If two packs both override the model config for the same animal type (e.g., both replace the COW config), the second one completely overwrites the first. The first pack's visual references will point to models that no longer exist, causing broken or missing visuals.
>
> **Only one pack should provide a config override per animal type.** If you're creating a balance-only pack, don't include config overrides -- you don't need them and they'll prevent breed packs from working alongside yours.

Config overrides are processed **before** subtypes are loaded, so your new subtypes can reference `visualAnimalIndex` values from your custom model config.

### Breed Metadata

When adding new breeds, register their display names and marker colours so the GUI shows them correctly:

```xml
<animals>
    <breeds>
        <breed name="MYBREED"
               displayName="$l10n_breed_mybreed"
               markerColour="0.8 0.3 0.1"/>
    </breeds>

    <!-- ... subtypes below ... -->
</animals>
```

| Attribute | Description |
|-----------|-------------|
| `name` | Breed identifier (uppercase, matches the `breed` attribute on subtypes) |
| `displayName` | Localized name for the GUI. Use `$l10n_` prefix to reference translations. |
| `markerColour` | RGB colour for the breed's map marker, as three space-separated floats (0.0-1.0) |

The `$l10n_` references are resolved from the global translation table, which includes your pack's translations (loaded before breed metadata).

### Breeding Groups

Define breeding restrictions for your breeds. Animals in a breeding group can only breed with other animals in the same group.

```xml
<animals>
    <breedingGroups>
        <group name="MYGROUP" maxFertilityAge="120">
            <subType name="COW_MYBREED"/>
            <subType name="BULL_MYBREED"/>
        </group>
    </breedingGroups>
</animals>
```

| Attribute | Description |
|-----------|-------------|
| `name` | Group identifier (uppercase) |
| `maxFertilityAge` | Maximum breeding age in months for males in this group (optional) |

---

## Translations

Translation files provide localized text for breed names, fill type titles, and store descriptions. English is the required base language -- always provide an English translation file. Additional languages are optional.

### File naming

Files use the prefix from `rlrm_pack.xml` plus `_{lang}.xml`:

```
translations/
├── translation_en.xml    (required -- English base)
├── translation_de.xml    (optional -- German)
├── translation_fr.xml    (optional -- French)
└── ...
```

RLRM tries the player's game language first, then falls back to English, then to German. Only the first matching file loads - there is no per-key merging across languages, so each translation file must be complete on its own.

### File format

Standard FS25 translation XML:

```xml
<?xml version="1.0" encoding="utf-8" standalone="no" ?>
<l10n>
    <texts>
        <!-- Fill type names (shown in transport/trading UI) -->
        <text name="fillType_cow_mybreed" text="My Breed Cow"/>
        <text name="fillType_bull_mybreed" text="My Breed Bull"/>

        <!-- Breed display names (shown in animal details) -->
        <text name="breed_mybreed" text="My Breed"/>
    </texts>
</l10n>
```

These translations are loaded into the global translation table, so they work with `$l10n_` references in your animals.xml and fill types.

---

## Fill Types

Each new breed needs a fill type registered in the game's fill type system. This is how FS25 tracks animals internally.

```xml
<?xml version="1.0" encoding="utf-8" standalone="no" ?>
<map>
    <fillTypes>
        <fillType name="COW_MYBREED" title="$l10n_fillType_cow_mybreed" showOnPriceTable="false">
            <physics massPerLiter="600.0" maxPhysicalSurfaceAngle="0"/>
            <economy pricePerLiter="4000"/>
            <image hud="$dataS/menu/hud/fillTypes/hud_fill_cow.png"/>
        </fillType>
        <fillType name="BULL_MYBREED" title="$l10n_fillType_bull_mybreed" showOnPriceTable="false">
            <physics massPerLiter="750.0" maxPhysicalSurfaceAngle="0"/>
            <economy pricePerLiter="4000"/>
            <image hud="$dataS/menu/hud/fillTypes/hud_fill_cow.png"/>
        </fillType>
    </fillTypes>
</map>
```

This uses the standard FS25 fill types format. The `$l10n_` titles reference your pack's translation files. You can reuse base game HUD icons (`$dataS/...`) or provide your own.

Fill types are only needed when adding new breeds. Balance packs that only override existing breeds don't need them.

---

## Load Order and Priority

Packs are loaded in **alphabetical order by FS25 mod name**. This order is deterministic and reproducible.

If two packs override the same property on the same subtype, the alphabetically later mod wins. You can use naming to control priority:

- `FS25_RLRM_CowBreeds` loads before `FS25_RLRM_ZZ_MyOverrides`
- A pack named with a `ZZ_` prefix can serve as a "final word" override layer

The load sequence within each pack is:

1. **Translations** -- loaded first so `$l10n_` keys resolve in later steps
2. **Fill types** -- registered so new subtypes can reference them
3. **Config overrides** -- model configs replaced before subtypes load
4. **Model reload** -- Lua-side model data refreshed from new configs
5. **Breed metadata** -- display names and marker colours registered
6. **New subtypes** -- loaded through the engine's `loadSubTypes`
7. **Property overrides** -- applied last, patching both existing and newly added subtypes
8. **Breeding groups** -- registered after all subtypes exist

---

## The modDesc.xml

A pack's `modDesc.xml` is a standard FS25 mod descriptor. It doesn't need any special entries -- the `rlrm_pack.xml` file is what RLRM looks for.

```xml
<?xml version="1.0" encoding="utf-8" standalone="no" ?>
<modDesc descVersion="106">
    <author>Your Name</author>
    <version>1.0.0.0</version>
    <title>
        <en>RLRM My Balance Pack</en>
    </title>
    <description>
        <en><![CDATA[Description of what your pack does.

Requires Realistic Livestock - Ritter version (FS25_RealisticLivestockRM).]]></en>
    </description>
    <iconFilename>$dataS/menu/hud/fillTypes/hud_fill_cow.png</iconFilename>
    <multiplayer supported="true"/>
</modDesc>
```

Mention the RLRM dependency in the description so players know the pack requires the base mod.

---

## Tips

- **Start with a balance pack** to learn the format. Override a few prices, test it, then build up from there.
- **Test in singleplayer first.** Use the console command `rmSetLoglevel * DEBUG` for detailed loading output in the game log.
- **Check the game log** for messages starting with `MapBridge: Animal pack` -- these show exactly what was detected, loaded, and any warnings.
- **Name your mod consistently.** Use the `FS25_RLRM_` prefix so players can identify it as an RLRM pack and so load order is predictable relative to other packs.
- **Don't use config overrides unless you need them.** If you're only changing values (prices, food, reproduction), skip config overrides entirely. This keeps your pack compatible with breed packs that do need them.
- **Use RLRM's own `xml/animals.xml` as reference** for the full subtype definition format, property names, and AnimCurve structures.

---

## Limitations

- **Cannot remove breeds.** Packs can add new breeds and override properties on existing ones, but cannot remove a breed that RLRM or another pack defines. This is a limit on what a *pack* can do, not on the player: the **Choose Animals For Sale** setting lets them hide any breed or age stage from the dealer, which stops it being stocked without removing its definition.
- **Cannot add new animal types.** Packs can only add subtypes within existing types (COW, PIG, SHEEP, HORSE, CHICKEN, and any types added by the map). Creating an entirely new animal type requires map-level support.
- **Cannot modify diseases.** The disease system is not exposed to packs.
- **One config override per animal type.** If two packs both override the model config for the same animal type, only the last one loaded takes effect and the other pack's visuals will break. RLRM detects this collision and warns the player - a startup dialog plus a log warning naming the packs involved. See [Config Overrides](#config-overrides).
- **No explicit priority system.** Load order is strictly alphabetical by mod name. There's no way to declare "load after pack X" -- use naming conventions to manage order.
