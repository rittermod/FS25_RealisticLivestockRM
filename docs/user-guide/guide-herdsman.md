# Herdsman Automation

The Herdsman handles your routine herd chores automatically, once a day. You set up **tasks** - each task does one job (sell, move, buy, castrate, name, inseminate, look after your horses, or vaccinate) to the animals a [saved filter](guide-saved-filters.md) picks out, in the pens you choose. Set your tasks once and the Herdsman keeps your herd in shape while you get on with farming.

> **Note:** This documentation was generated with AI assistance and may contain inaccuracies. If you spot an error, please [open an issue](https://github.com/rittermod/FS25_RealisticLivestockRM/issues).

---

## What the Herdsman does

Once per in-game day, the Herdsman works through your enabled tasks and carries each one out. It runs on the server - including dedicated servers - so it keeps working whether or not anyone has the menu open. The Herdsman charges a **daily wage** for its work, shown in your farm finances.

---

## Opening the Herdsman

Open the **RL Menu** (default **Right Shift + O**, or press **R** at one of your pens) and pick the **Herdsman** tab, between **Messages** and **Settings**. It is part of your own-herd menu, so it isn't shown when you open the menu at an animal dealer.

In multiplayer you need the **trade animals** farm permission to create or edit tasks.

---

## How a task works

Every task has four parts:

- **Operation** (labeled **Task** in the menu) - the single job it does: Sell, Move, Buy, Castrate, Naming, Artificial Insemination, Horse Care, or Vaccination.
- **Filter** - a [saved filter](guide-saved-filters.md) that decides which animals qualify. (Naming tasks don't need one.)
- **Pens** - which of your husbandries the task looks at. A task with **no pens does nothing** - it never falls back to "all pens".
- **Settings** - the options for that operation (how many animals per day, a buy budget, a semen source, and so on), plus an on/off switch. Some operations have no options of their own - Horse Care and Vaccination just need a filter and their pens - so this section only shows the on/off switch. The daily limit and the buy budget apply to each selected pen separately, not to the task as a whole: a Sell task limited to 5 animals a day on three pens can sell 15.

Each day the Herdsman runs tasks in a **fixed order**:

**Sell -> Move -> Buy -> Castrate -> Naming -> Artificial Insemination -> Horse Care -> Vaccination**

So selling happens before buying - a "sell old cows, then buy young ones" pair does the sensible thing within a single day. Vaccination runs last, so animals sold that day are never vaccinated and animals bought that day are.

---

## The operations

- **Sell** - sells matching animals back to the dealer. It never sells or marks an animal showing symptoms of a disease - treat or cull those yourself.
- **Move** - moves matching animals to another of your pens, or delivers them to a **butcher** (an Extended Production Point). On a butcher delivery, animals outside the butcher's accepted age range, and sick animals, are skipped and reported. A move between your own pens takes them along.
- **Buy** - buys animals from the dealer into each chosen pen, up to a daily budget and count per pen.
- **Castrate** - castrates matching males. Not available for chickens.
- **Naming** - gives unnamed animals names, either at random or alphabetically. No filter needed.
- **Artificial Insemination** - inseminates matching females using stored semen (from a source you choose, or any available).
- **Horse Care** - exercises and grooms matching horses every day, so their Daily Riding and Cleanliness stay up and they hold their sale value. Only available for horse pens.
- **Vaccination** - gives matching animals every vaccine they are due, the same doses you can give from the Diseases dialog. An animal is due when it has no protection, or when a month or less of protection is left, so it never goes unprotected. It skips animals the disease can't reach yet - too young for it, or for mastitis, a female that is neither pregnant nor in milk - and animals visibly sick with that disease; an animal about to come of age is dosed a month ahead. Each dose costs what it costs in the Diseases dialog, on top of the wage, but the day's doses are charged as one medicine expense and reported as one message per pen with the number of animals and the total. Only available for cattle, sheep, pig and alpaca pens.

Sell, Move, Castrate and Artificial Insemination tasks have an **Action** setting. **Perform** carries out the job. **Mark only** just flags the animals it would have picked, at a reduced wage, so you can check them and act yourself: nothing is sold, moved, castrated or inseminated, and each flagged animal's row shows a note such as *Herdsman marked for selling*. The marks are refreshed each day.

When more animals match than the daily limit allows, the Herdsman picks them in this order:

- **Sell** - highest price first.
- **Move** and **Artificial Insemination** - best genetics first, so a capped Move to a butcher sends your best animals first.
- **Buy** - cheapest first.

---

## Setting up a task

1. **New task** - creates a draft task to start from (a disabled Sell task).
2. **Operation** - pick the job you want. If you change the job later, a filter the new job can't use is unbound for you - a chicken-only filter on Castrate, or a filter tied to a non-horse animal on Horse Care - along with any pens that no longer suit the job. A filter that isn't tied to one animal type is kept as long as its **Show on** suits the job: Buy takes **All screens** or **Dealer screens** filters, every other job **All screens** or **Owned-herd screens**. If the task was already **enabled**, it is switched off for you and keeps your change - finish setting it up, then switch it back on.
3. **Filter** - open the filter picker and choose a saved filter. Only filters that suit the operation are offered, so it helps to [build the filter first](guide-saved-filters.md). Changing the filter can leave the task with no usable pens; if that happens and the task was enabled, it is switched off for you and keeps your change.
4. **Pens** - open the pen picker and select one or more husbandries. Only pens matching the filter's animal type are offered. On a Move task, picking the pen you were moving *to* as a source clears the destination - and again, an enabled task is switched off for you rather than losing the change.
5. **Settings** - set the per-operation options.
6. **Enable** - switch the task on. A task needs a filter (except Naming), at least one pen and, on Move, a destination. If one is missing, the task switches back off when your changes are saved, and keeps them.

You can **Duplicate** a task as a starting point for another, or **Delete** one (with a confirmation).

---

## Good to know

- **No pens, no action.** A task with no pens selected does nothing - this is deliberate, so a half-finished task can't run wild across your whole farm.
- **Order matters.** Because Sell runs before Buy, a sell-then-buy pair refreshes a pen in one day rather than two.
- **Start narrow, then watch.** Test a new task with a tight filter and check the **Messages** tab to see exactly what the Herdsman did before widening it.
- **The filter is the whole game.** The Herdsman only ever touches animals the filter matches - a well-built filter is what keeps automation safe.
- **Horse Care needs a filter like any other task.** Only Naming works without one, so a Horse Care task with no filter selected can't stay switched on. A filter that simply matches every horse is a perfectly good starting point.
- **Horse Care bills every horse, every day.** The wage is per horse per day and there is no cap and no upper limit on herd size, so a large stable keeps paying for as long as the task is enabled - and it keeps paying whether or not you ever sell the horse. The payoff comes when you sell, so it suits a stable you trade from rather than one you only breed in. We recommend selling a horse manually after a full riding session to sell at the highest possible price - selling automatically via the Herdsman forgoes the riding share of the care bonus for that day, though the fitness and cleanliness built up by earlier care still count.
- **The game's own animal worker also rides and grooms horses.** Hire it on the Animals page with Manage Animal Workers. On a pen Horse Care already looks after, it usually finds nothing left to do and charges nothing; a horse you rode that day gets dirty again, and the worker grooms and bills it.
- **Vaccination's first day is the expensive one.** A new Vaccination task doses every due animal in its pens at once; after that it only doses an animal when its protection is about to run out, every six or twelve months depending on the vaccine. A filter that matches every animal of the pen's type is a good starting point. Nothing is vaccinated while diseases are switched off in the settings.

---

## Multiplayer

Tasks belong to your farm: everyone on the farm shares the same list, and other farms have their own. They run on the host or dedicated server. You need the **trade animals** permission to edit them, and the results sync to every player.
