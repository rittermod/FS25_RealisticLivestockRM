# Hand-Crafting Saveable Filters (Preview)

This page is for power users who want to author saveable animal filters by hand.
It documents the on-disk XML format, every available field and comparator, the
rules the evaluator follows, and a few real examples.

> **Status:** Most players should use the in-game filter editor (RL Menu ->
> Settings -> Filters) - see the [Saved Filters guide](guide-saved-filters.md).
> This page remains a reference for the on-disk XML format and power-user
> hand-editing, and is intentionally kept out of the site navigation.

> **Note:** This documentation was generated with AI assistance and may
> contain inaccuracies. If you spot an error, please
> [open an issue](https://github.com/rittermod/FS25_RealisticLivestockRM/issues).

---

## Where the file lives

Filters are stored together with your RL settings, in your savegame folder:

```
~/Library/Application Support/FarmingSimulator2025/savegame<N>/rm_RlSettings.xml
```

(or the equivalent on your platform)

Edit only when **the game is closed for that savegame**. The host writes
this file out on every settings change and on every game save, so live edits
will be overwritten. Always make a backup before editing.

If you have not yet opened the savegame after installing the version that
moved filter persistence into `rm_RlSettings.xml`, the file may exist with
only your settings and no `<filters>` block. Add the block as shown below.

---

## Top-level structure

The file root is `<rm_RlSettings>`. Filters live in a single `<filters>`
block as a sibling of the settings entries:

```xml
<?xml version="1.0" encoding="utf-8" standalone="no"?>
<rm_RlSettings version="1">
    <deathEnabled value="2"/>
    <diseasesEnabled value="2"/>
    <!-- ... other settings ... -->
    <filters>
        <filter id="my_first_filter" name="My first filter" animalType="COW" farmId="1" version="1">
            <group op="AND">
                <condition field="age" cmp=">=" value="60.000000"/>
                <condition field="isPregnant" cmp="==" value="false"/>
            </group>
        </filter>
        <!-- more <filter> entries ... -->
    </filters>
</rm_RlSettings>
```

Every filter has exactly one root `<group>`. Group operators can be nested
arbitrarily deep.

---

## `<filter>` attributes

| Attribute | Required | Type | Notes |
|-----------|:--------:|------|-------|
| `id` | yes | string | Stable unique identifier. Any string works; production filters created via the in-game flow use the prefix `rlFilter_`. Hand-authored ids can be any short slug, e.g. `cow_butcher`. Must be unique within the file. |
| `name` | recommended | string | Display name shown in the in-game cycle chip and lists. Optional: the loader defaults a missing name to an empty string. Only `id` and the `.group` subtree are hard requirements. |
| `animalType` | optional | string | Scope to a single animal type: `COW`, `SHEEP`, `PIG`, `CHICKEN`, `HORSE` and bridge-mod types (e.g. `RABBIT` on Witcombe). Omit the attribute for global scope (filter shows on every animal-type tab). |
| `farmId` | optional | integer | Scope to a single farm by id (`1`, `2`, ...). Omit for global scope (visible to every farm). |
| `usage` | optional | string | Controls which screens show the filter: `ANY` (default), `OWNED` (owned-herd screens), `DEALER` (buy screen). Unknown values load as `ANY` with a warning. |
| `version` | optional | integer | Schema version for forward compatibility. Default `1`. Leave at `1` unless future docs say otherwise. |

A filter with `animalType="COW" farmId="1"` only appears on Farm 1's cow tab.
A filter with both attributes omitted appears everywhere. The attributes are
**immutable** once a filter is created through the in-game flow; for
hand-authored filters they are honoured as-written each load.

---

## Groups: `AND` / `OR`

Every filter has exactly one root `<group>`. A group has one attribute,
`op`, which is either `AND` or `OR`. A group's children are any mix of
`<condition>` and `<group>` elements:

```xml
<group op="AND">
    <condition .../>
    <group op="OR">
        <condition .../>
        <condition .../>
    </group>
</group>
```

**Vacuous truth (important):**

- An empty `AND` group (`<group op="AND"/>` with no children) evaluates to
  **true** for every animal. Useful as a "match-all" placeholder.
- An empty `OR` group evaluates to **false** for every animal.
- Any other (non-AND, non-OR) op is treated as false to fail-closed.

There is **no `NOT` operator** in the current schema. Negation lives at the
condition level via `!=`, `notin`, `notcontains`, or by inverting a bool
condition (`isPregnant == false`).

---

## Conditions

A condition tests a single field against one or more values. There are two
shapes depending on the comparator:

### Scalar form (one value)

```xml
<condition field="age" cmp=">=" value="60.000000"/>
<condition field="gender" cmp="==" value="male"/>
<condition field="isPregnant" cmp="==" value="false"/>
<condition field="name" cmp="notcontains" value="keep"/>
```

The `value` attribute is interpreted per the field's type - see the
[Field reference](#field-reference) below.

### List form (multiple values, only for `in` / `notin`)

```xml
<condition field="subType" cmp="in">
    <value value="BULL_HOLSTEIN"/>
    <value value="BULL_REDHOLSTEIN"/>
    <value value="BULL_JERSEY"/>
</condition>
```

Use the list form for `in` and `notin` comparators. Each `<value>` element
has a single `value` attribute. An empty list (no `<value>` children):

- `in` against an empty list -> false (the animal can't be "in" nothing)
- `notin` against an empty list -> true (vacuously not-in)

Mixing forms (a `value=` attribute *and* `<value>` children on the same
condition) is undefined; the engine reads the form that matches the
comparator's expected shape.

---

## Field reference

| Field | Type | Comparators | Scope | Notes |
|-------|------|-------------|-------|-------|
| `age` | number | `<` `<=` `==` `!=` `>=` `>` `in` `notin` | all | Months, integer in practice. |
| `gender` | enum | `==` `!=` `in` `notin` | all | Values: `male`, `female` (lowercase, internal keys). |
| `isCastrated` | bool | `==` | all | `true` / `false`. |
| `isPregnant` | bool | `==` | all | `true` / `false`. |
| `isLactating` | bool | `==` | **COW only** | Other species ignore this field. Goats (a SHEEP subtype, `subType="GOAT"`) do track lactation internally, but this filter field is scoped to COW, so an `isLactating` condition always evaluates false for goats. |
| `hasName` | bool | `==` | all | True if the animal has a non-empty player-set name. |
| `hasAnyDisease` | bool | `==` | all | True if at least one disease is currently active. A cured disease (still counting down its immunity) and a genetic carrier state (CVM) do NOT count - those animals match `hasAnyDisease == false`, the same "Healthy" the quick filter offers. This also steers herdsman rules built on this field: a "sell diseased animals" rule no longer selects cured animals or CVM carriers. |
| `hasAnyMark` | bool | `==` | all | True if any mark is active (player-set or AI-manager). |
| `name` | string | `contains` `notcontains` | all | Case-insensitive substring match. Unnamed animals are treated as empty string, so `notcontains anything` is true for them. |
| `weight` | number | `<` `<=` `==` `!=` `>=` `>` `in` `notin` | all | **Monitor-gated.** Returns no value when the animal's monitor is not active; the condition then evaluates to false. |
| `health` | number | same as weight | all | **Monitor-gated.** Same as weight. |
| `genetics.metabolism` | number (0-99) | `<` `<=` `==` `!=` `>=` `>` `in` `notin` | all | Scaled to 0-99. |
| `genetics.health` | number (0-99) | same | all | Scaled to 0-99. |
| `genetics.fertility` | number (0-99) | same | all | Scaled to 0-99. |
| `genetics.quality` | number (0-99) | same | all | Scaled to 0-99. |
| `genetics.productivity` | number (0-99) | same | **COW, SHEEP, CHICKEN** | Scaled to 0-99. Other species don't carry productivity. |
| `genetics.overall` | number (0-99) | same | all | Average of the present genetics traits, then scaled to 0-99. Matches the on-screen overall genetics number. |
| `subType` | enum | `==` `!=` `in` `notin` | all | The internal breed/variant string. Examples (vary by map/bridge): `COW_HOLSTEIN`, `BULL_HOLSTEIN`, `SHEEP_TEXEL`, `RAM_TEXEL`, `CHICKEN`, `CHICKEN_ROOSTER`, `RABBIT`, `RABBIT_MALE`. To find the exact string for a breed on your map, open `rm_RlAnimalSystem.xml` and look at the `subType="..."` attribute on any `<animal>` entry. |

**Type rules at a glance:**

- **number** comparators require numeric values on both sides. Integer or
  float literals both work in the XML; ages are integer in practice,
  genetics/weight/health are floats.
- **bool** values are the literal strings `true` / `false`.
- **enum** values are stable lowercase / uppercase internal keys (see notes
  per field). Enum keys are case-sensitive.
- **string** comparators (`contains` / `notcontains`) are case-**in**sensitive
  substring matches.

`==` and `!=` enforce **type strictness**: a number-vs-string comparison
returns false rather than fail-open, so a non-numeric typo like `value="abc"`
on the `age` field yields nil and will silently exclude every animal.

---

## Comparators by type

| Type | Comparators |
|------|-------------|
| number | `<`  `<=`  `==`  `!=`  `>=`  `>`  `in`  `notin` |
| bool | `==` only |
| enum | `==`  `!=`  `in`  `notin` |
| string | `contains`  `notcontains` |

`!=` is intentionally absent for bool (use `==` against the negated value).
`==` and `!=` are intentionally absent for string (the substring matcher
is the only intended path; for an exact match, use `contains <fullName>`
on a sufficiently-unique substring).

There is no `between` operator. Express ranges as
`AND(field >= low, field <= high)`.

---

## What each comparator means

Plain-English glosses for each comparator - the same wording the in-game
editor now shows as its **Compare** labels (see the
[Saved Filters guide](guide-saved-filters.md#reading-the-comparison-labels)),
repeated here for quick reference while hand-authoring. In XML the `cmp`
attribute is always the raw symbol in the left column; the editor renders the
"Reads as" label for it - except a bool field with `==` drops the operator
entirely in the editor (e.g. `Pregnant No`, not `Pregnant is No`).

| Comparator | Reads as | Example |
|------------|----------|---------|
| `<` | is less than | `age < 12` |
| `<=` | is at most | `age <= 12` |
| `==` | is | `gender == male` |
| `!=` | is not | `gender != male` |
| `>=` | is at least | `age >= 30` |
| `>` | is more than | `weight > 500` |
| `in` | is one of | `subType in [BULL_HOLSTEIN, BULL_JERSEY]` |
| `notin` | is none of | `subType notin [BULL_HOLSTEIN]` |
| `contains` | contains (case-insensitive) | `name contains betty` |
| `notcontains` | does not contain (case-insensitive) | `name notcontains keep` |

Inside XML attribute values, remember to entity-encode `<` as `&lt;` and
`>` as `&gt;` (see the [quick reference card](#quick-reference-card)).

---

## Behaviours that catch authors out

**Monitor-gated fields silently fail.** `weight` and `health` only return
a value when the animal's monitor is active. If you write
`<condition field="weight" cmp=">=" value="200"/>`, animals without an
active monitor never match. Combine with another field if you want a
fallback.

**`name` on unnamed animals is the empty string, not nil.** This means
`name notcontains "keep"` is **true** for every unnamed animal - they
vacuously do not contain "keep". This is intentional so that herds with
mostly-unnamed animals still get filtered sensibly.

**`hasName` and `name` are independent.** `hasName == false` filters to
unnamed animals; `name contains "betty"` filters to animals named with
"betty" anywhere in their name. Use the one that matches your intent.

**Empty `AND` matches everything.** A condition that fails to load
(unknown field, unknown comparator, etc.) is dropped during load, but
the *group* is preserved. If every condition in an `AND` group is
dropped, you end up with an empty `AND` that matches every animal.
Watch the game log for `RLFilterSerialization` warnings on first load
to catch this.

**Genetics are 0-99, not raw multipliers.** The engine stores genetics
internally as 0.25-1.75 multipliers but every filter field exposes them
on the same 0-99 scale you see on the in-game info card.
`genetics.health >= 75` does what you expect.

**Filter `id` collisions silently overwrite.** If two `<filter>` entries
share the same `id`, the second one wins on load. Pick distinct ids.

---

## Validation behaviour

The filter loader is fail-closed: a malformed condition is **dropped with
a warning**, not silently passed through. On first load after editing,
watch the game log for warnings like:

| Log line | Meaning | Fix |
|----------|---------|-----|
| `RLFilterSerialization.readCondition: unknown field 'X' ...` | Field name doesn't exist in the catalog. | Check spelling against the [Field reference](#field-reference). |
| `RLFilterSerialization.readCondition: cmp 'X' is not in whitelist for field 'Y' ...` | Comparator isn't valid for that field's type. | Pick a comparator from the field's row in the table. |
| `RLFilterSerialization.readCondition: missing field/cmp at ...` | One of the required attributes is absent. | Add the missing attribute. |
| `RLFilterSerialization.readFilter: missing id` | `<filter>` lacks an `id` attribute. | Add a unique `id`. |
| `RLFilterSerialization.readFilter: filter id=... has no .group subtree; skipping (corrupt save?)` | `<filter>` has no `<group>` child. | Wrap conditions in a `<group op="AND">...</group>`. |

A filter that loads cleanly but matches every animal usually means an
empty `AND` group - see *Empty `AND` matches everything* above.

---

## Examples

The filters below are real working examples. Adapt the `id`, `name`,
`animalType`, `farmId`, and the breed strings (`subType` values) to your
own savegame.

### 1. Cull old or non-pregnant cows

```xml
<filter id="cow_cull" name="Cow cull" animalType="COW" farmId="1" version="1">
    <group op="OR">
        <condition field="genetics.overall" cmp="&lt;" value="75.000000"/>
        <group op="AND">
            <condition field="age" cmp=">=" value="48.000000"/>
            <condition field="isPregnant" cmp="==" value="false"/>
        </group>
    </group>
</filter>
```

Selects any cow with overall genetics below 75, **or** any cow that is at
least 48 months old and not currently pregnant. Note `&lt;` - the `<`
character must be entity-encoded inside an XML attribute value.

### 2. Sell chickens for profit, but spare marked birds

```xml
<filter id="chicken_sell_profit" name="Sell chickens for profit" animalType="CHICKEN" farmId="1" version="1">
    <group op="AND">
        <condition field="subType" cmp="in">
            <value value="CHICKEN"/>
            <value value="CHICKEN_ROOSTER"/>
        </condition>
        <group op="OR">
            <condition field="age" cmp=">=" value="60.000000"/>
            <group op="AND">
                <condition field="age" cmp=">=" value="6.000000"/>
                <condition field="hasAnyMark" cmp="==" value="false"/>
            </group>
        </group>
    </group>
</filter>
```

Restricts to base chicken subtypes, then matches anything 60+ months old,
or 6+ months old without any mark.

### 3. Move "any animal called 'keep' should NOT match" to a butcher list

```xml
<filter id="cow_butcher" name="Move to butcher" animalType="COW" farmId="1" version="1">
    <group op="AND">
        <condition field="age" cmp=">=" value="12.000000"/>
        <condition field="isPregnant" cmp="==" value="false"/>
        <condition field="hasAnyMark" cmp="==" value="false"/>
        <condition field="name" cmp="notcontains" value="keep"/>
    </group>
</filter>
```

Cows aged 12+ months, not pregnant, no active marks, with no "keep"
substring in their name (case-insensitive). Unnamed cows pass the name
check vacuously, so the filter is still useful in mostly-unnamed herds.

### 4. Find dairy breeding bulls in a specific genetics window

```xml
<filter id="dairy_bull_pick" name="Dairy breeding bull" animalType="COW" farmId="1" version="1">
    <group op="AND">
        <condition field="gender" cmp="==" value="male"/>
        <condition field="genetics.overall" cmp=">=" value="80.000000"/>
        <condition field="subType" cmp="in">
            <value value="BULL_HOLSTEIN"/>
            <value value="BULL_REDHOLSTEIN"/>
            <value value="BULL_JERSEY"/>
        </condition>
    </group>
</filter>
```

Bulls (male cows) with overall genetics 80+ and a dairy-breed subtype.

### 5. Match-all (placeholder while you draft)

```xml
<filter id="match_all" name="All animals" version="1">
    <group op="AND"/>
</filter>
```

Empty `AND` is vacuously true, so this filter matches every animal in
scope. Useful as a starting point when iterating: edit the group, reload,
test, repeat.

---

## Limitations and notes

- No `NOT` operator. Use `!=`, `notin`, `notcontains`, or invert a bool
  condition.
- No `between` operator. Use `AND(field >= low, field <= high)`.
- No date-based fields. `age` is months only.
- Per-mark-kind filtering (player vs. AI-manager mark) is not in this
  schema; only the generic `hasAnyMark` is exposed.
- The `subType` strings depend on which mods/maps you have installed.
  When in doubt, copy the exact string from an existing
  `<animal subType="..."/>` line in `rm_RlAnimalSystem.xml`.
- Multiplayer: filters are server-authoritative. Hand-edits on the host
  propagate to clients automatically on next reconnect or filter
  mutation.

---

## Quick reference card

```xml
<rm_RlSettings>
    <filters>
        <filter id="<unique>" name="<display>" animalType="<TYPE>" farmId="<N>" usage="ANY|OWNED|DEALER" version="1">
            <group op="AND|OR">
                <condition field="<key>" cmp="<op>" value="<scalar>"/>
                <condition field="<key>" cmp="in|notin">
                    <value value="<v1>"/>
                    <value value="<v2>"/>
                </condition>
                <group op="AND|OR"> ... </group>
            </group>
        </filter>
    </filters>
</rm_RlSettings>
```

XML entity reminders inside attribute values:
- `<` -> `&lt;`
- `>` -> `&gt;`
- `&` -> `&amp;`
- `"` -> `&quot;`
