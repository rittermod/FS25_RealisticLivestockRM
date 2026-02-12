# Settings Reference

All Realistic Livestock RM settings are accessible from the mod settings menu in-game. Settings are saved per-savegame and synced in multiplayer.

> **Note:** This documentation was generated with AI assistance and may contain inaccuracies. If you spot an error, please [open an issue](https://github.com/rittermod/FS25_RealisticLivestockRM/issues).

---

## Death & Accidents

| Setting | Default | Options | Description |
|---------|---------|---------|-------------|
| **Death Enabled** | On | Off / On | Toggles all death mechanics (old age, low health, accidents). When off, animals live indefinitely. |
| **Accidents Chance** | 100% | 0% – 200% (10% steps) | Scales the probability of random accident deaths. 0% disables accidents entirely. 200% doubles the chance. Only available when Death is enabled. |

*With death disabled, animals never die from any cause — but diseases can still make them sick if diseases are enabled.*

---

## Food

| Setting | Default | Options | Description |
|---------|---------|---------|-------------|
| **Food Scale** | 1x | 0.5x – 5x (0.5 steps) | Multiplies all animal food consumption. At 0.5x, animals eat half as much. At 5x, they eat five times more. Does not affect water or straw. |

*This setting stacks with metabolism genetics. An animal with high metabolism at maximum food scale will eat dramatically more than a low-metabolism animal at minimum scale.*

---

## Dealer & AI

| Setting | Default | Options | Description |
|---------|---------|---------|-------------|
| **Max Dealer Animals** | 50 | 20 – 200 (10 steps) | Maximum number of animals per species available in the animal dealer. Higher values give more choice when buying. |
| **Reset Dealer** | — | Button | Restocks the dealer with a fresh set of randomised animals. Use this if you want different genetics or breeds available. |
| **Reset AI Animals** | — | Button | Refreshes the artificial insemination animal pool. Use this if the current AI pool has poor genetics. |

---

## Customisation

| Setting | Default | Options | Description |
|---------|---------|---------|-------------|
| **Tag Colour** | — | Button | Opens the ear tag colour picker. Customise the colour of animal identification tags. |
| **Export CSV** | — | Button | Exports all animal data to a CSV file. Useful for tracking herd statistics in a spreadsheet. |

---

## Messages

| Setting | Default | Options | Description |
|---------|---------|---------|-------------|
| **Max Messages** | 500 | 100 – 5,000 | Maximum number of messages stored in the message log. Older messages are removed when the limit is reached. |
| **Message Summary** | Off | Off / On | When off, each event (birth, death, disease) generates an individual message. When on, events are aggregated into daily summaries. |

*Summary mode reduces message clutter in large herds but provides less detail per event.*

---

## Diseases

| Setting | Default | Options | Description |
|---------|---------|---------|-------------|
| **Diseases Enabled** | On | Off / On | Toggles the entire disease system. When off, no animal can contract, spread, or suffer from any disease. |
| **Disease Chance** | 1x | 0.25x – 5x | Scales the base probability of all disease infections. At 0.25x, diseases are 4 times less common. At 5x, they're 5 times more frequent. Only available when Diseases are enabled. |

*Disabling diseases removes Mastitis, CVM, Foot & Mouth, PED, and Avian Influenza entirely. Already-infected animals are not automatically cured when diseases are toggled off.*

---

## Custom Animals

| Setting | Default | Options | Description |
|---------|---------|---------|-------------|
| **Custom Animals** | Off | Off / On | Enables loading a custom animals.xml file instead of the default. Allows modifying animal stats, production curves, prices, etc. **Requires game restart to take effect.** Not available in multiplayer. |
| **Animals XML** | — | Button | Opens a file picker to select the path to your custom animals.xml. Only available when Custom Animals is enabled. |

*Custom animals is for advanced users who want to tweak animal statistics. The default animals.xml is located in the mod's xml/ folder and can be used as a template.*

---

## Dependencies

Some settings depend on others being enabled:

```
Death Enabled → Accidents Chance (only when Death is On)
Diseases Enabled → Disease Chance (only when Diseases are On)
Custom Animals → Animals XML (only when Custom Animals is On)
```

*Dependent settings are greyed out when their parent setting is disabled.*
