# Changelog

## 1.3.1.0-dev.3:
- Added "Horse Care" as a Herdsman task - it exercises and grooms the horses in a chosen horse pen every day so their Daily Riding and Cleanliness stay up and they hold their sale value, charging a wage for every horse it looks after.
- Changed the corrupt-genetics log warnings from one-per-session to counted reports - repeated bad values now log a running total at 10, 100 and 1000 occurrences with the latest offender named, instead of going silent after the first.
- Changed the Herdsman task editor to put the task's on/off switch at the bottom of its settings instead of near the top - you fill in the job, filter and pens first and switch the task on last.
- Fixed a Herdsman task keeping a filter its new job cannot use when you change the Operation - the filter and any now-unsuitable pens are cleared, so the task can be repaired instead of being stuck with a filter the picker will not offer.
- Fixed a change to an already-enabled Herdsman task being thrown away when it left the task incomplete - the task is now switched off for you and keeps your change, ready to finish and switch back on.
- Added user-guide coverage for the herdsman's Horse Care task, plus a FAQ entry on why a pen can show only one animal in husbandry.
- Fixed the user guide still listing a Shift + T keybind for the visual-animals control - that key was removed when the control moved into RL Menu > Settings > General.

## 1.3.1.0-dev.2:
- Added "Dealer Animal Quality" in RL Menu > Settings > General - choose whether the animal dealer stocks Budget, Standard or Premium animals. Budget stock is weaker and cheaper; Premium stock is stronger and costs more. Changing it discards the current dealer stock and restocks with new animals, and it does not affect the AI animals used for insemination. Admin only in multiplayer.
- Fixed the animal dealer's poorest stock lingering forever on established saves - listings now rotate off the shelf after at most two in-game days.
- Fixed the herdsman ignoring the "Dealer Animal Quality" setting when it buys animals - it always paid the Standard price, so Budget saves were overcharged and Premium saves underpaid; it now pays the same markup the dealer shows.
- Added user-guide coverage for the dealer animal quality setting.

## 1.3.1.0-dev.1:
- Added "Choose Animals For Sale" in RL Menu > Settings > General - pick which animals and age groups the animal dealer offers, and the dealer restocks to match. Admins can change it in multiplayer, and every player's dealer updates to match.
- Changed animal dealer quality to follow a natural bell curve instead of piling animals up at the best and worst extremes. Most dealer animals are middling: an "Extremely good" one drops from roughly one in 25 to under one in 200, "Very bad" ones from about one in 20 to about one in 160, and an animal's traits now sit closer to each other. Existing dealer stock is untouched and converges to the new curve as the dealer restocks.
- Changed what saved genetics filters and herdsman goals match - they keep their stored 0-99 thresholds but now cover a different share of dealer stock because of that curve change, so a filter like "overall genetics at least 90" goes from a few percent of the dealer's animals to well under one percent. If a saved filter suddenly returns nothing at the dealer, lower its threshold.
- Fixed saved filters and herdsman rules being lost (and overwritten on the next save) when loading a save that has no Realistic Livestock animal data.
- Added user-guide coverage for choosing which animals the dealer offers.

## 1.3.0.1:
- Improved the saved-filter editor - comparison operators now read as plain English ("is at least", "is one of", "does not contain", ...) in the Compare dropdown and each condition row, instead of programmer symbols.
- Fixed the saved-filter editor showing the Gender, Breed, and Name fields as raw internal names in the field picker and condition rows.

## 1.3.0.0:
### Heads up before you update
Things that affect existing saves:
- The old herdsman automation no longer runs. Set up your automation again in the new Herdsman menu.
- The old animal screen is removed: your pens, on-foot dealers, the R key, and trailer-to-butcher deliveries all open the new RL Menu now.
- All mod settings moved into the RL Menu's Settings tab; the in-game Settings page is now a single button that opens it.
- Breeding ages were adjusted (goats from 8 months, horse stallions from 24, hens stop hatching by ~5 years, roosters retire at 6), so existing herds breed on a slightly different schedule.
- The "max visible animals" control moved to RL Menu > Settings > General (the Shift+T key was removed).

### New livestock menu
- Added the RL Menu as the mod's main animal-management interface - a standalone tabbed menu.
- Added opening it from anywhere with your own key (default Right Shift + O, set in Controls), plus from your pens, on-foot dealers, the R key, and trailers.
- Added memory of your selected pen and animal as you switch tabs, with the husbandry list sorted alphabetically.
- Added status icons on every animal card - pregnancy, recovering, infertile or castrated, lactating, producing wool, and laying eggs.
- Added a Manage tab - animal list with a detail pane (pedigree, genetics, diseases, inputs and outputs) plus per-animal actions: Mark, Monitor, Rename, Diseases, Inseminate, Castrate. Genetics shown as a 0-99 score next to each trait.
- Added a Messages tab - chronological feed with single and bulk delete.
- Added a Move tab - move animals between pens or deliver them to a butcher, one or many at a time; a feed-runway estimate shows how many months the current feed lasts.
- Added a Sell tab with a shopping-cart summary (count, price, fee, total).
- Added a Buy tab - browse dealer animals with per-row prices and a running cart total; buy one or many via a destination picker.
- Added an AI tab - browse dealer bulls by species, pick a straw quantity with live price preview, favourite bulls, and buy straws without leaving the menu.
- Added Saveable Filters - build reusable filters in-game (Settings > Filters) on age, gender, pregnancy, lactation, genetics, subtype, weight, health, marks, and name; multi-value "in / not in" via a Select Values dialog; cross-species matching when Animal type = ANY.
- Added F on the Manage/Buy/Sell/Move tabs to cycle filters (shown as a chip), with a per-filter "Show on" axis (All / Owned herd / Dealer) to keep the cycle tidy, and one-click saving of the current Quick Filter as a reusable filter.
- Added a Settings tab - all mod settings now live here instead of on the in-game settings page, including a new "Animal Country of Origin" setting that chooses the country new animals are registered in (ear tags, identifiers). New animals only.
- Added trailer handling in the menu - move animals between a pen and a parked trailer, buy into or sell from a trailer at the dealer, and load or unload horses from a standalone trailer out in the world.
- Added a Herdsman tab - create, duplicate, and delete named automation tasks; each runs one action (sell, buy, castrate, naming, AI insemination, or move) on the animals matched by a saved filter across the pens you choose. A move task can target a butcher (Extended Production Point); animals outside its age range are skipped and reported.
- Added a task editor - name, enable or disable, per-action options (animals per day, budget, naming convention, AI semen choice), and a choice to mark matching animals for review or perform the action outright, with per-row help tooltips.
- Added automatic day-change task runs, server-side, in order (sell, buy, castrate, naming, AI, move), respecting each task's cap, budget, and the destination's free space; a herdsman wage applies per farm. The herdsman reports what it did in the Messages tab (folded into daily counts when message summary mode is on).
- Added server-authoritative multiplayer for everything in the new menu - it syncs to all players, open menus refresh live, and late-joining players receive the full filter and rule set.
- Added new user guides for Saved Filters and Herdsman automation, and made the user guide site downloadable as a PDF.

### Multiplayer fixes
- Fixed husbandry log messages (animal buy/sell/move, births, deaths, and daily summaries) appearing only after rejoining instead of live for connected players.
- Fixed inseminating a female from the menu silently doing nothing on dedicated servers and clients (no pregnancy, and a straw was wasted); straw counts now stay in sync across all players.
- Fixed a mother's post-birth recovery appearing stuck as "recovering" instead of counting down live, which had wrongly blocked inseminating her again until a relog.
- Fixed rapidly triggering two animal trades of the same kind (buy, sell, or move) risking the wrong animals or leaving the menu stuck - trades now run one at a time with a "trade in progress" notice and timeout recovery.
- Fixed animals from a DLC that is installed but not active in the session being loaded, which showed them as the wrong breed or gender, or corrupted them when bought, for players without the DLC.

### Fixed
- Fixed cows on Hof Bergmann v1.4 cow pastures not producing milk (all cow breeds produce milk cans again).
- Fixed the pen feed forecast under-estimating the months-of-feed range at higher days-per-month settings - it now reflects the real days of feed remaining.
- Fixed a declined semen purchase (e.g. not enough money) using up dealer spawn space, so repeated declined attempts can no longer eventually make valid purchases fail with a "no space" message.
- Fixed an FPS stutter when switching the active implement (G) - the animal-visibility settings dialog now loads once per session instead of on every switch.
- Fixed pressing Esc in an animal pen's menu opened from the in-game menu (Animals page) closing straight to the game instead of returning to the in-game menu.

### Compatibility
- Documented that the LSFM Animal Transport Pack's animal herding/driving feature does not work with RLRM (it opens the animal screen through the pack's custom transport object, which the new menu does not recognise); the rest of the pack is unaffected. Hof Bergmann bundles this pack - see the mod-compatibility guide.

## 1.2.6.0:

### Added
- Added trailer loading and unloading at a pen - walk up to a parked livestock trailer to move animals between the pen and the trailer.
- Added trailer buying and selling at the dealer - with a trailer present, the Buy tab buys animals straight into the trailer and the Sell tab sells straight from it.
- Added standalone trailer handling out in the world - walk up to a parked trailer to load loose horses into it and unload them back out.
- Added a Herdsman tab in the RL Menu - create, duplicate, and delete named automation tasks. Each task runs one action (sell, buy, castrate, naming, AI insemination, or move) on the animals matched by one of your saved filters, across the pens you choose.
- Added a herdsman task editor - set a name, enable or disable the task, configure its options (animals per day, budget, naming convention, AI semen choice), and choose whether the task marks matching animals for review or performs the action outright. Per-row help tooltips explain each option.
- Added filter and target-pen pickers inside the task editor - the filter list is scoped to the task's action (buy draws from the dealer pool; sell, castrate, and AI from your own herd) and the pen list to the filter's animal type. A task needs a filter and at least one pen to be enabled, so incomplete drafts can be saved disabled.
- Added automatic day-change task runs, server-side, in order (sell, buy, castrate, naming, AI, move), respecting each task's animal cap, budget, and the destination pen's free space. A herdsman wage is deducted per farm.
- Added day-change notifications - the herdsman posts the same per-pen messages the legacy herdsman did (sold, bought, castrated, named, inseminated, moved, or "marked for ..."), folded into daily counts when message summary mode is on.
- Added an orange banner warning when a pen still has the legacy herdsman enabled - the menu-based tasks run alongside the legacy per-pen herdsman, not instead of it, so avoid running both for the same pen or actions and wages get applied twice.
- Added multiplayer sync for herdsman tasks - create / edit / delete sync to all players and an open menu refreshes live; the day-change actions replicate to clients, including on dedicated servers.

### Changed
- Changed livestock trailers to load and unload in the RL Menu instead of the legacy animal screen.
- Changed trailer transfers to run server-side through the same events the legacy screen used, so they sync to all players, including on dedicated servers.

### Fixed
- Fixed goats showing wool instead of milk production in the animal genetics overview, across the RL Menu, the legacy info dialog, and the on-foot look-at panel.
- Fixed pregnancies not tracking each animal's configured gestation period closely, especially at higher days-per-period settings where they previously ran too long (contributed by borondy).
- Fixed young animals maturing far too fast at higher days-per-period settings - they now grow to full size over their proper age range (contributed by borondy).
- Fixed settings changed in the RL Menu (Settings > General) not syncing to the server in multiplayer - they now persist across save/reload and update live for other players, where previously these changes were silently lost on dedicated servers.
- Hardened against a possible crash when a mod or game code path looked up a missing (nil) text label - the lookup now falls back safely instead of stopping the game, and logs a warning.

### Translations
- Fixed the Danish herdsman sell tooltip to show the specific sell age again instead of a vaguer phrasing that dropped it.
- Added French translations for the new herdsman task editor, filter editor, daily-summary, mod-compatibility, and saved-filter strings that were still showing in English (contributed by squall39).
- Fixed the German animal-move confirmation showing a leftover price that the other languages never displayed.
- Updated Italian with a native-speaker refresh across the menu, settings, and help text, plus the herdsman move strings that were still showing in English (contributed by FirenzeIT).
- Added Turkish translations for the many menu, herdsman, settings, and message strings that were still showing in English (contributed by Cyber-Syntax).
- Changed new filter and herdsman labels to fall back to English instead of showing raw text codes in languages that have not translated them yet.

### Compatibility
- Changed FS25_AnimalFoodCalculator to a blocking conflict instead of a dismissible warning - it breaks RLRM's animal feeding and milk/egg/wool output, so the game stops and prompts a restart to disable it.

## 1.2.5.0:

### Added
- Added a mod compatibility bridge - RLRM can now coexist with some foreign mods that overlap its hooks, via per-mod shim files in `mod_support/<ModName>/` (same layout as the map-support bridges). The framework activates automatically when a registered foreign mod is detected; shim files self-disable cleanly when their target mod is absent, with no impact on RLRM-only setups.

### Changed
- Improved Hereford calves to use the breed-accurate red-and-white coat (adults shipped in 1.2.4.0; UV-layout tip from [MA] BavarianRedneck).
- Changed quick filter persistence to be tab-local and shown in the chip ("QF" alone or combined with a saved-filter name); it clears automatically when you leave the tab.

### Fixed
- Fixed selling or buying animals via a livestock trailer at the dealer logging `Error in AnimalSellEvent` / `Error in AnimalBuyEvent ... missing method 'addRLMessage'`. The sales themselves always completed.
- Fixed animal lists showing wrong breeds or species in multiplayer on clients missing a DLC the server has installed (e.g. Highland Cattle rendering as Water Buffalo). Server data was always correct; only the receiving client misrendered.
- Fixed player-initiated insemination from non-host clients not propagating to the server and other clients within one network frame (previously applied locally only).
- Fixed empty dewars (0 straws remaining) surviving save/load or a storage round-trip; they now self-delete on the server in every code path. Affected saves clean up on next load.
- Fixed newborns of the same farm inheriting "Children" counts from another species' male with the same identifier (e.g. a Texel ram showing 61 children due to a rooster collision). Existing bogus counts are not auto-cleaned.
- Fixed the AI insemination "not enough money" check not blocking dewar purchases priced above farm balance (both RL Menu AI tab and the legacy R-key flow).
- Fixed the Artificial Insemination dialog's Inseminate button staying latched to the first row instead of enabling and disabling per selected dewar.
- Fixed per-visual `canBeBought="false"` on animal sale stages being silently ignored at the dealer. Packs can restrict a breed to juvenile-only or adult-only sales; default bundle behavior unchanged.
- Fixed pens overflowing past capacity when multiple pregnancies mature on the same day-change. Existing overcap saves heal gradually via natural deaths or sold animals.
- Fixed defensive pregnancy backfill on legacy / orphaned saves passing nil instead of the mother's quality for offspring of mothers missing `impregnatedBy.quality`. Normal pregnancies were always correct.
- Fixed the quick filter dialog silently applying a "Healthy animals only" filter on open + OK; the disease filter now defaults to any.
- Fixed quick filter dialog polish - added a title, aligned the scrollbar inside the dialog body, stopped clamping slider ranges to a previously-applied filter, and fixed option rows drifting to the wrong segment or slider thumb after scrolling. Applies to both the new RL Menu and the legacy R-key screen.
- Fixed Settings > General not being admin-only end-to-end. Non-admin players could previously edit most rows; changes would revert or briefly affect the server.

### Documentation
- Documented the Hof Bergmann support page and FAQ - the HB bull stable's BULLSPERM trigger stays empty under RLRM (HB models bull sperm as a milk output; RLRM only produces milk for lactating female cows). HB pasture bulls remain decorative.

### Compatibility
- Added Seasonal Wool Production (Argsy Gaming) compatibility - RLRM and SWP now coexist without the previous double-production of wool. SWP handles wool as a seasonal event with a single output per sheep per season; per-pen yield matches vanilla SWP based on flock size (mature sheep aged >= 8 months). Trade-off: wool yield does not reflect RLRM per-animal genetics.

### RL Menu (preview - work in progress)
- Added in-game editing of Saveable Filters from Settings > Filters. All engine field types supported (numeric, boolean, gender, subType, name); multi-value "in" / "not in" via a Select Values dialog; cross-species matching when Animal type = ANY. Out-of-range numeric values are rejected with a visible hint.
- Added a per-screen "Show on" axis (All / Owned-herd / Dealer) to Saveable Filters so the F-cycle stays uncrowded once you have several filters.
- Added a Save filter button to the Quick Filter dialog that turns the current dialog state into a new saveable filter and opens Settings > Filters on the new row. Price conditions cannot be saved and are dropped with a warning.
- Added a feed-runway estimate to the Pen Info and Move tabs in the "Total Capacity" row - a `(~N-Mm)` range shows how many in-game months the current feed lasts, accounting for lactation, gestation surge, scheduled births, and per-animal metabolism. The capacity bar and text turn red when the runway drops below 2 months.
- Changed Settings > Filters so New filter / Duplicate picks the next free suffix as max existing N + 1, so names no longer collide after deleting earlier-numbered entries. Saved-filter cards now use the dealer-card visual style so more fit on screen.
- Changed the Animal Dealer to open the new RL Menu (Buy tab) at the shop counter and on walk-up; trailer loading still uses the legacy screen.
- Fixed filter create / rename / delete not refreshing peer Info / Buy / Sell / Move tabs live in multiplayer, which needed a menu reopen.
- Fixed RL Menu tab and header icons rendering at about half base-game size.

### Herdsman automation rules (preview - backend groundwork, no in-game UI yet)
- Added the foundation for upcoming saveable Herdsman rules that pair a saved filter with an automated operation (sell, buy, castrate, naming, or AI) across chosen pens. Rules persist across save/load in rm_RlSettings.xml; a corrupt or hand-edited rule record is dropped safely on load. Multiplayer: rule add / edit / delete propagate to all players, and a player who joins mid-session receives the server's full rule set on connect.

## 1.2.4.0:

### Added
- Added map support for Le Mechet by MA7Studio (https://farming-simulator.com/mod.php?mod_id=357964) - four French cow breeds (Charolaise, Montbeliarde, Simmental, Vosgienne) with bull variants; full breeding, genetics, and reproduction; per-breed pricing, milk curves, and reproduction signatures preserved from the map's source XML.
- Added an in-game warning when two map bridges or animal packs replace the same animal type's husbandry. The second one wins and the first one's animals can become invisible (ghost animals); RLRM now shows a dismissible warning at mission start so the cause is visible instead of silent.
- Added clean loading of Witcombe Park Farm 1.3.0.0 (v4) with the existing map bridge.
- Added saveable animal filters - define filters that match on age, gender, pregnancy, lactation, genetics, subtype, weight, health, marks, and name, nested with AND/OR groups; filters persist across sessions in the savegame. For now filters are authored by hand-editing rm_RlSettings.xml - the in-game editor ships in a future release.
- Added F on the Info / Buy / Sell / Move tabs to cycle through saved filters; the active filter shows as a chip on the tab. Filter selection is shared across Info / Move / Sell; Buy keeps its own selection per dealer flow.
- Added multiplayer sync for filter create / update / delete across all connected players (admin or tradeAnimals permission required); late-joining clients receive the full filter set on connect.
- Added a Settings tab with two subtabs - [General] surfaces the existing RL settings (now editable from both the new menu and the legacy GAME SETTINGS page, reordered into thematic groups: Mortality, Health & Disease, Husbandry & Economy, Custom Animals, Message Log, Display Preferences, Tools & Admin), and [Filters] lists your saved filters (read-only view today; in-game editor in a future release). Toggling a setting on either General page reflects on the other when re-opened.

### Changed
- Improved the Hereford adult cow and bull skin to a more breed-accurate red-and-white coat. Texture contributed by [MA] BavarianRedneck.

### Fixed
- Fixed the finance overview showing the `Missing 'finance_medicine' in l10n_en.xml` fallback instead of "Medicine" for animal medicine costs.

### Translations
- Improved the French translation with a refresh by community contributor @squall39 (PR #83) - native-speaker corrections to existing strings and translations for the new RL Tabbed Menu strings (Messages, Info, Move, Sell, Buy, AI tabs).

### Documentation
- Improved the user guide cattle milk chart to reconcile with the breed-range table; a footnote spells out which factors compose into the table range (the chart is the lifetime age envelope; the table folds in lactation-phase factor and genetics multiplier).
- Added a Filter Hand-Crafting reference page in the user guide for power users authoring saveable filters in rm_RlSettings.xml until the in-game editor lands.

### Compatibility
- Documented that Le Mechet is NOT compatible with the Cow Breeds Pack for RLRM (FS25_CowBreedsRLRM) unless you use the latest development version of the Cow Breeds Pack - both replace the cow husbandry config and only one can win. Use Le Mechet alone, or pair it with the latest dev Cow Breeds Pack. The new in-game warning will fire if you load both together.
- Removed Hereford from the dealer when Le Mechet is the active map.

## 1.2.3.0:

### Added
- Added a non-blocking startup warning for known-trouble mods - a dismissible dialog at game start with a link to the new Mod Compatibility reference page; hard-conflict mods are unchanged.
- Added support-log diagnostics for lag triage and bug reports - per-pen timing summaries for day-change/cluster-update/visual-update/buy operations, an `rlDumpSettings` console command, and a one-time startup dump of active RL settings (set log level to DEBUG to see timing detail).

### Changed
- Improved bulk animal operations (move, sell, buy, AI sell) and multiplayer sync of reproduction/death cycles - large herds no longer freeze the game; clients receive a single update per affected husbandry instead of one per animal; day-change with simultaneous births collapses to one cluster-update per pen.
- Changed pregnancy food and water consumption to cap at 2x the non-pregnant baseline (previously sows with large litters reached 4-9x during late gestation; cattle and sheep with typical litters are unaffected). Builds on contributor PR #72 - thanks @borondy.

### Fixed
- Fixed the multiplayer hard-conflict dialog not firing on every peer; pure clients connecting to a host with a known-conflict mod are now returned to the main menu instead of silently entering a broken session.
- Fixed pregnant and lactating cows/goats not actually drinking more water - the multiplier was being computed but silently discarded.
- Fixed pregnancy state occasionally clearing the pregnant flag inconsistently after an internal cleanup, which affected pregnancy sync across multiplayer peers and sale animals at the dealer.
- Fixed a multiplayer error that left pig and horse pregnancies unsynced to clients (both natural conception and AI-straw insemination would appear to succeed on the host but never replicate to other players).
- Fixed a multiplayer crash on per-animal load/unload from the trailer animal screen - clicking the single-row load button crashed the client and corrupted the move packet on the server. Multi-select bulk was the only working path until now.
- Fixed rabbits on Witcombe never getting pregnant - the Witcombe bridge now ships a fertility-by-age curve for the RABBIT type.
- Fixed Witcombe Highland Cattle rendering as a small Angus calf at all ages and Witcombe Herefords rendering as Limousin-coloured Angus instead of the white-face Hereford. Witcombe's custom Hereford dealer-menu thumbnails are preserved.
- Fixed Jersey cows on Witcombe showing the marker spray and monitor collar permanently regardless of actual state; the same fix applies to Witcombe-bridge sheep and pig breeds (Texel / Suffolk / Blue-Faced Leicester rams, Gloucestershire Old Spot boar) and Hereford bulls.
- Fixed the marker tool crashing on Jersey or Highland (added cream and auburn marker colours; unregistered breeds fall back to white).
- Fixed the RL Menu Messages tab not clearing the per-pen unread flag on open; existing saves with stuck unread flags will auto-heal the first time you open the Messages tab.
- Fixed redundant "animals changed" notifications firing multiple times per mutation.

### Documentation
- Added a Breeding Reference page in the user guide - per-breed table of female and male breeding ages, gestation, and peak litter sizes across all base species.
- Fixed user guide accuracy - Witcombe Hereford peak (the value at 18 months is not the peak; the peak is at 24 months), PED disease fatality framing (time-since-infection rather than age-when-infected), and lactation-bonus wording.

## 1.2.2.0:
- Added Witcombe map support - new UK breeds (Jersey, Gloucestershire Old Spot, Texel, Suffolk, Blue Faced Leicester) with full breeding, genetics, and reproduction; rabbits get viable weights, litter sizes, and consumption rates; automatic version-aware compatibility
- Added a Buy tab to the RL Menu (preview) - browse dealer animals, see per-row prices and a running cart total, then buy one or many at a time via a destination-picker flow
- Added an Artificial Insemination tab to the RL Menu (preview) - browse dealer bulls by species, pick a straw quantity with live price preview, favourite bulls, and buy straws without leaving the menu
- Changed Hereford on Witcombe to use a heritage breed profile - 9-month gestation, premium pricing (300/3000), and an 18-month sell-price peak
- Changed Info tab genetics to show a 0-99 score next to each label (e.g. "97 - Extremely high") so animals within the same bucket can be compared at a glance
- Fixed the RL Messages tab not showing "Bought/Sold N animal(s) for €X" entries in singleplayer after buying or selling (previously these entries only appeared in multiplayer)
- Fixed a potential multiplayer crash when changing monitor, name, or disease treatment on an animal while the husbandry is being sold or demolished
- Fixed the multiplayer insemination result notification to clients reporting success when the insemination actually failed
- Fixed the RL Menu (preview) Sell and Info tabs showing a stale farm balance until the next action instead of refreshing immediately in multiplayer

## 1.2.1.0:

### Added
- Added multiplayer support for the "Reset Animal Dealer" and "Reset AI Animals" buttons (admin-only in MP, syncs to all players)
- Added a Sell tab to the RL Menu with a shopping cart summary (selected count, price, fee, total); animals marked as non-sellable are filtered out

### Changed
- Changed the husbandry selector to sort alphabetically by name
- Changed the RL Menu to remember the selected husbandry and animal when switching between Manage, Move, and Sell tabs
- Renamed the "Info" tab to "Manage" to better reflect its actions (mark, inseminate, monitor, etc.)
- Reordered the tabs to Sell, Move, Manage, Messages

### Fixed
- Fixed straw pickup from a dewar not syncing to the server in multiplayer (the dewar no longer "refills" on reconnect)
- Fixed the empty straw hand tool not being deleted from client inventory after insemination or return in multiplayer
- Fixed animal mark/unmark not updating the 3D visual marker immediately when unmarking (previously required relog)
- Fixed a potential multiplayer crash when receiving unknown mark keys from newer mod versions
- Fixed a straw hand tool crash when no player is carrying it
- Fixed a crash when selling an animal from a livestock trailer at the animal dealer
- Fixed a crash when opening the animal trailer screen near a rideable horse created by third-party mods (e.g. AdditionalContracts animal missions)
- Fixed prop horses from third-party mods being incorrectly converted to real animals when loaded onto trailers or into pens
- Fixed animals marked as non-sellable being sellable after loading onto a trailer
- Fixed single sell/move clearing other checkbox selections
- Fixed status icons jumping position when switching between tabs
- Fixed animal age not showing in the RL Menu stats area

## 1.2.0.1:
- Fixed deprecated fillUnit warning in game log for semen dewar

## 1.2.0.0:

### Added
- Added the new RL Menu (assign key in Settings > Controls) - a standalone tabbed menu. The legacy animal screen (R key) still works unchanged
- Added a Messages tab - chronological message feed with single and bulk delete
- Added an Info tab - husbandry selector, animal list with detail pane (pedigree, genetics, diseases, inputs/outputs), and action buttons (Mark, Monitor, Rename, Diseases, Inseminate, Castrate)
- Added a Move tab - move animals between husbandries or to butchers with single-move and bulk-move using checkbox multi-select
- Added status icons on animal list cards showing pregnancy, recovering, infertile/castrated, lactating, producing wool, and laying eggs at a glance

### Changed
- Rewrote the semen dewar as a vehicle/pallet - fixes game freeze when looking at the dewar, multiplayer pickup failures, and invisible dewars after mid-game purchase
- Changed dewar state (straws, bull genetics) to persist through save/load and object storage cycles

### Fixed
- Fixed a crash in third-party mods that inspect stored pallets (e.g. Time Saving Stock Check) when a semen dewar is placed in object storage
- Fixed multiplayer desync - mark, castrate, monitor toggle, rename, and disease treatment changes from a client now sync to all other connected players
- Fixed all pre-existing animals getting the same identity (e.g. "UK 1 1") when installing RL on an existing save for the first time - also self-heals saves already affected
- Fixed fillType errors in the log when third-party selling station mods reference the ANIMAL category

### Translations
- Updated the Czech translation (community contribution by Kynuska)
- Added the Hungarian translation (community contribution by Toamsz93)
- Added missing translation keys across all 16 languages

## 1.1.4.0:
- Added diagnostic logging for fillType mismatches in pallet and milk output
- Disabled four horse breeds not natively supported by Hof Bergmann (Pinto, Chestnut, Bay, Dun) from the dealer - existing savegame horses of those breeds are unaffected
- Fixed horse breed visuals on Hof Bergmann - adult horses no longer display as foals, breed colors now match correctly, and the foal-to-adult model transition now works
- Fixed horse riding and equipment on Hof Bergmann v1.4 - saddles, carriages, and tools from the Horse Addon Pack now attach correctly
- Fixed the dealer generating sale animals for breeds marked as not purchasable on the current map
- Fixed wool not spawning on Hof Bergmann v1.4 - the bridge now remaps WOOL to SHEEPWOOL_SHEARED to match HB's husbandry buildings
- Fixed chicken eggs not spawning on Hof Bergmann v1.4 - the bridge now remaps EGG to EGG_HB to match HB's husbandry buildings
- Fixed the Hof Bergmann egg incubator failing to add hatched chicks to the husbandry when RLRM is active
- Fixed a crash when an animal output curve returns nil, which could silently stop all production in a building
- Fixed bridge output overrides replacing valid production curves with empty ones when only the fillType needed remapping
- Fixed the Hof Bergmann user guide's horse breed availability, riding notes, and wild duck clarification

## 1.1.3.0:
- Added pre-validation for bulk buy - shows which animals can't be purchased and why before confirming
- Added diagnostic logging for animal loading, breeding, and pack compatibility troubleshooting
- Added warnings when animals are lost due to removed packs or breed mismatches
- Fixed bridge animals (rabbits, quail, etc.) getting duplicate IDs in multiplayer, causing animals to disappear on clients
- Fixed the bridge animal ID counter, which now tracks per-type counters with savegame persistence
- Fixed bulk buy silently failing when map husbandries reject animal breeds (e.g. Hereford in Hof Bergmann filtered pens)
- Fixed existing saves with duplicate bridge animal IDs, which are now automatically repaired on load

## 1.1.2.0:

### Added
- Added an animal pack system - third-party mods can add breeds, override animal properties, or provide custom balance via rlrm_pack.xml
- Added Hof Bergmann 1.4 support with alpacas, quail, corrected chicken visuals, and version detection
- Added cross-color alpaca breeding (any male color can breed with any female color)
- Added an exit path so the RL animal screen returns to the in-game menu's Animals tab when opened from there
- Added an Info-tab default so the RL animal screen opens on the Info tab when entered from the in-game menu's Animals tab

### Changed
- Refactored Animal.lua internally into focused modules (reproduction, health, persistence, serialization)

### Fixed
- Fixed the animal list scroll position jumping every 5 seconds in the ESC menu's Animals tab
- Fixed a click sound playing every 5 seconds while viewing the animal list
- Fixed a crash when a husbandry doesn't register a pallet or milk fillType that its animals produce
- Fixed animal model accumulation when maps redefine existing animal types
- Fixed base game reloads clobbering RLRM's superset animal configs
- Fixed random death money compensation (33% sell price) not reaching the farm balance
- Fixed bridge animal descriptions showing "Missing" in the animal info dialog
- Fixed pig ear tag errors on Hof Bergmann maps
- Fixed sale animals of non-reproductive subtypes (e.g. bulls, dogs) incorrectly becoming pregnant
- Fixed bridge animals' offspring receiving the wrong breed when using a non-standard subtype layout
- Fixed map-defined subtypes for existing animal types not loading alongside base game configs

### Translations
- Improved the Italian translation (community contribution)
- Improved the German translation (community contribution)

### Documentation
- Added user documentation for Hof Bergmann map support (exotic animals, known limitations, FAQ)

## 1.1.1.0:
- Added version-aware map support - detects installed map version and loads the matching configuration
- Added warning dialog when an untested map version is detected (with link to report issues)
- Added breed and visual override support for map-based animal subtypes
- Fixed division-by-zero risk in horse riding fitness calculation at boundary threshold values
- Fixed horse riding value not being clamped (could accept values outside 0-100 range)
- Fixed male animals could theoretically become pregnant (missing gender guard in reproduction check)
- Fixed AI herdsman castrate notifications showing "marked for castrating" instead of "castrated" when in execute mode
- Fixed AI herdsman state tracking error after auto-buying animals
- Fixed BUM ID branding on cows showing all zeros and overlapping text

## 1.1.0.3:
- Fixed selected animal jumping to a different animal in the in-game animal menu

## 1.1.0.2:
- Changed invalid messages to be discarded on savegame load and handled gracefully in the UI
- Fixed crash on Messages tab caused by unrecognized message IDs from older dev versions

## 1.1.0.1:
- Fixed crash when moving animals between pens (nil subtraction on visual animal count)

## 1.1.0.0:
- Added Move tab for transferring animals between husbandries with destination picker and bulk move
- Added custom icons for all Animal Screen tabs
- Hid the castration tab in the herdsman screen for chickens (not applicable)
- Refactored internally for code quality and testability
- Fixed visual glitch in herdsman screen when enabling castration

## 1.0.2.0:
- Added genetics display in animal names (average score, or full breakdown per trait)
- Added sort by genetics option for animal lists
- Added selection count on bulk action buttons
- Fixed move messages in husbandry message log (were silently failing due to incorrect message keys)
- Fixed move messages showing wrong direction (to/from was swapped)
- Fixed typo in move message ("1 animals" -> "1 animal")

## 1.0.1.1:
- Fixed compatibility with Hof Bergmann's subtype filter for animal pens

## 1.0.1.0:
- Added Hof Bergmann map support - exotic animals (ducks, geese, cats, rabbits) now support full breeding and reproduction
- Added basic support for butchers using Extended Production Point (EPP) mod
- Improved offspring subtype selection for maps with non-standard animal configurations
- Fixed "Manage Animals" (R) key interfering with other mods' keybindings in different menu tabs (e.g. RemoveContract)
- Fixed bulk move allowing more animals than target pen capacity
- Fixed error when moving animals to Extended Production Points (EPP butchers)
- Added missing translation keys across all languages (sourced from EnhancedLivestock where available)
- Updated Italian translation (contributed by FirenzeIT)

## 1.0.0.0 (Stable):
- Added "Manage Animals" (R) button to in-game animal menu for quick access to animal management
- Added "Select" (A) action to check/uncheck selection boxes in buy and sell dialogs
- Changed the insemination button to be disabled when a female is ineligible (pregnant, too young, recovering)
- Changed the monitor button to show a "Removing..." state when removal is pending
- Fixed keybinding collisions - each action now has a unique key (D=Diseases, C=Castrate, M=Monitor, I=Insemination, X=Mark)
- Fixed info buttons (Mother/Father/Children) intercepting Mark/Castrate keypresses - now mouse-only
- Fixed insemination button incorrectly showing on male animals
- Fixed monitor visual not disappearing when removing monitor from animal
- Fixed batch "Remove All Monitors" button not reflecting pending removal state
- Fixed milk/wool/goat milk info not showing on dedicated server clients

## 0.6.1.0 (2026-02-16):
- Fixed AI dialog insemination not syncing in multiplayer
- Fixed AI dialog insemination blocked for cows that never gave birth
- Fixed server crash when client inseminates cow with straw
- Fixed stream corruption in AI auto-insemination event
- Fixed pregnancy event silently failing to match animals on client
- Fixed dewars bought mid-game not syncing to connected clients in multiplayer
- Fixed client-side error when buying semen in multiplayer
- Fixed disease treatment toggle not syncing to server in multiplayer
- Fixed settings dependency check using undefined variable
- Fixed error spam when dismounting horse outside pen in multiplayer
- Fixed black screen when multiplayer client tries to ride a horse
- Fixed multiplayer client unable to clean horses

## 0.6.0.0 (2026-02-13):
- Added daily summary mode for message log
- Added "Reset AI Animals" button to settings
- Fixed freeze when selling animals with active filter
- Fixed possible milk production loss from birth errors
- Fixed missing texture declaration causing visual glitches
- Merged community translations
- Added a user documentation site with per-species guides
- Added FS25_EnhancedLivestock as an incompatible mod

## 0.5.0.0 (2026-01-31):
- Added compatibility handling for FS25_MoreVisualAnimals conflict
- Improved pregnancy handling
- Fixed wrong text string for water/straw in monitor menu
- Added Italian (it) translation

## 0.4.2.0 (2026-01-24):
- Improved fallback handling for days per month calculation
- Improved failover for animal subtypes and breeds

## 0.4.1.0 (2026-01-22):
- Fixed wrong text for when females can reproduce
- Fixed death message count for auto-sold newborns
- Fixed crash with invalid animal root node in visual animals

## 0.4.0.0 (2026-01-18):
- Removed Font Library dependency by inlining 3D text rendering directly in the mod

## 0.3.0.0 (2026-01-18):
- Added the initial Ritter version, based on Arrow-kb's Realistic Livestock v1.2.0.5
- Added automatic savegame migration from Arrow-kb's Realistic Livestock
- Added Highland Bulls support (based on Renfordt's PR 389)
