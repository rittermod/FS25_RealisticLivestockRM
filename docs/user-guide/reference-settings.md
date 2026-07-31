# Settings Reference

All Realistic Livestock RM settings live in the RL Menu's **Settings** tab (it opens on the **General** sub-tab, where all of the options below are). The quickest way there: open the in-game menu (ESC), go to **Game Settings**, scroll to the **Realistic Livestock** section at the bottom, and press **Open Settings**. You can also open the RL Menu directly with its hotkey - it defaults to **Right Shift + O** (remappable in Settings -> Controls); look for "Open RL Menu" in the game's input bindings. If your installation was set up before this default was added, the key may not be assigned automatically - bind or reset it manually. *(Older versions listed every setting directly on the Game Settings page; those rows have moved here.)*

Most settings are saved per-savegame and synced in multiplayer, and in multiplayer can only be changed by an admin - everyone else sees them read-only. The one exception is **Maximum Visible Animals** (under Customisation below): it is a per-machine display preference, saved locally on your own computer, never synced, and any player can change their own.

> **Note:** This documentation was generated with AI assistance and may contain inaccuracies. If you spot an error, please [open an issue](https://github.com/rittermod/FS25_RealisticLivestockRM/issues).

---

## Death & Accidents

| Setting | Default | Options | Description |
|---------|---------|---------|-------------|
| **Animal Death** | On | Off / On | Toggles all death mechanics (old age, low health, accidents, birth complications, and fatal diseases). When off, animals live indefinitely. The ModHub build labels this setting "Animal Removal". |
| **Accident Chance** | 100% | 0% - 200% (10% steps) | Scales the probability of random accident deaths. 0% disables accidents entirely. 200% doubles the chance. Only available when Death is enabled. |

*With death disabled, animals never die from any cause - but diseases can still make them sick if diseases are enabled.*

---

## Food

| Setting | Default | Options | Description |
|---------|---------|---------|-------------|
| **Food Scale** | 1x | 0.5x - 5x (0.5 steps) | Multiplies all animal food consumption. At 0.5x, animals eat half as much. At 5x, they eat five times more. Does not affect water or straw. |

*This setting stacks with metabolism genetics. An animal with high metabolism at maximum food scale will eat dramatically more than a low-metabolism animal at minimum scale.*

---

## Dealer & AI

| Setting | Default | Options | Description |
|---------|---------|---------|-------------|
| **Max Dealer Animals** | 50 | 20-200 (10 steps) | Maximum number of animals per species available in the animal dealer. Higher values give more choice when buying. |
| **Dealer Animal Quality** | Standard | Budget / Standard / Premium | How good - and how expensive - the animals the dealer offers are. Budget stock is weaker and cheaper; Premium stock is stronger and costs more. Changing this **discards the current dealer stock and restocks** with new animals, because each animal's genetics are fixed when it is generated. Does not affect the AI animals used for insemination. Admin only in multiplayer. |
| **Reset Animal Dealer** | - | Button | Restocks the dealer with a fresh set of randomised animals. Use this if you want different genetics or breeds available. Admin only in multiplayer. |
| **Choose Animals For Sale** | - | Button | Opens a checklist of every animal the dealer can offer, grouped into sections - one per breed *and sex*, so "Holstein" and "Holstein Bull" are separate sections. Each section lists one row per age group. A row is ticked when the dealer currently offers it. Untick one and the dealer stops stocking it; tick it back and it returns. Pressing **OK** after a change restocks the dealer for **every** animal type, exactly like Reset Animal Dealer; **Back** discards. Admin only in multiplayer. |
| **Reset AI Animals** | - | Button | Refreshes the artificial insemination animal pool. Use this if the current AI pool has poor genetics. Admin only in multiplayer. |

---

## Animal Origin

| Setting | Default | Options | Description |
|---------|---------|---------|-------------|
| **Animal Country of Origin** | Map default | Map default / 16 countries | Sets the country new animals are registered in - the country code on their ear tags and identifiers. Takes effect immediately for newborn animals, dealer stock, and AI animals. Existing animals keep the country they were registered in. |

*"Map default" uses the country built into the map you're playing; maps the mod doesn't recognise fall back to the United Kingdom - this setting is the fix if that doesn't suit your farm. Available countries: United Kingdom, United States, China, France, Poland, Germany, Canada, Estonia, Italy, Czech Republic, Russia, Sweden, Norway, Finland, Japan, and Spain. A small share of animals are deliberately imported from abroad - roughly 1 in 8 dealer and AI animals and 1 in 100 newborns - so an occasional foreign tag while an override is active is normal, not a bug. Tip: after changing the country, press **Reset Animal Dealer** to restock the dealer with animals from the new origin right away.*

---

## Customisation

| Setting | Default | Options | Description |
|---------|---------|---------|-------------|
| **Change Tag Colour** | - | Button | Opens the ear tag colour picker. Customise the colour of animal identification tags. |
| **Export To CSV** | - | Button | Exports all animal data to a CSV file. Useful for tracking herd statistics in a spreadsheet. |
| **Set Maximum Visual Animals** | 2 | Button (opens a slider) | Sets the maximum number of animals rendered per pen. A per-machine display/performance preference: each player sets their own value, it is not synced in multiplayer or saved per-savegame, and any player (not just admins) can change it. The dialog's **Recommended** button suggests a value based on your graphics settings. |

---

## Messages

| Setting | Default | Options | Description |
|---------|---------|---------|-------------|
| **Maximum Amount of Messages** | 500 | 100-5,000 | Maximum number of messages stored per husbandry; older messages are removed when the limit is reached. |
| **Message Log Summaries** | Off | Off / On | When off, each event (birth, death, disease) generates an individual message. When on, events are aggregated into daily summaries. |

*Summary mode reduces message clutter in large herds but provides less detail per event.*

---

## Diseases

| Setting | Default | Options | Description |
|---------|---------|---------|-------------|
| **Diseases Enabled** | On | Off / On | Toggles the entire disease system. When off, new infections, disease spread, and disease effects are suspended. Already-infected animals are not cured; their diseases resume when the system is re-enabled. |
| **Disease Chance** | 1x | 0.25x - 5x | Scales the base probability of all disease infections. At 0.25x, diseases are 4 times less common. At 5x, they're 5 times more frequent. Only available when Diseases are enabled. |

*Disabling diseases suspends Mastitis, CVM, Foot & Mouth, PED, and Avian Influenza - it stops new infections, spread, and effects but does not cure already-infected animals; their diseases resume when re-enabled.*

---

## Genetics Display

| Setting | Default | Options | Description |
|---------|---------|---------|-------------|
| **Genetics Display** | Off | Off / Short / Long | Shows numeric genetics values in animal names. "Short" shows average genetics as a single number (e.g., `[72]`). "Long" shows the average plus individual trait scores (e.g., `[72-68:75:80:65:70]`). |
| **Genetics Position** | Prefix | Prefix / Postfix | Controls where genetics values appear in the animal's name. "Prefix" places them before the name, "Postfix" places them after. |
| **Sort by Genetics** | Off | Off / On | When enabled, animals within each group are sorted by average genetics (highest first) before age, rather than the default type and age sorting. Diseased animals always sort to the top. |

*The genetics tag format for Long mode is `[avg-metabolism:health:fertility:quality:productivity]` (productivity only shown for species that have it). Values are scaled 0-99.*

These settings only change how genetics are DISPLAYED. They are unrelated to **Dealer Animal Quality**, which changes what the dealer actually generates.

---

## Custom Animals

| Setting | Default | Options | Description |
|---------|---------|---------|-------------|
| **Use Custom Animals** | Off | Off / On | Enables loading a custom animals.xml file instead of the default. Allows modifying animal stats, production curves, prices, etc. **Requires game restart to take effect.** Not available in multiplayer. |
| **Set Animals XML Path** | - | Button | Opens a file picker to select the path to your custom animals.xml. Only available when Custom Animals is enabled. |

*Custom animals is for advanced users who want to tweak animal statistics. The default animals.xml is located in the mod's xml/ folder and can be used as a template.*

*This is a different mechanism from **Choose Animals For Sale** (under Dealer & AI) and neither replaces the other: the selector hides breeds and age groups from what the dealer stocks, while Custom Animals swaps the entire animal definition file for one of your own.*

---

## Dependencies

Some settings depend on others being enabled:

```
Animal Death -> Accident Chance (only when Death is On)
Diseases Enabled -> Disease Chance (only when Diseases are On)
Use Custom Animals -> Set Animals XML Path (only when Custom Animals is On)
```

*Dependent settings are greyed out when their parent setting is disabled.*
