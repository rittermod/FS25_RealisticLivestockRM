# Herdsman Automation

The Herdsman handles your routine herd chores automatically, once a day. You set up **tasks** - each task does one job (sell, move, buy, castrate, name, inseminate, or look after your horses) to the animals a [saved filter](guide-saved-filters.md) picks out, in the pens you choose. Set your tasks once and the Herdsman keeps your herd in shape while you get on with farming.

> **Note:** This documentation was generated with AI assistance and may contain inaccuracies. If you spot an error, please [open an issue](https://github.com/rittermod/FS25_RealisticLivestockRM/issues).

---

## What the Herdsman does

Once per in-game day, the Herdsman works through your enabled tasks and carries each one out. It runs on the server - including dedicated servers - so it keeps working whether or not anyone has the menu open. The Herdsman charges a **daily wage** for its work, shown in your farm finances.

---

## Opening the Herdsman

Open the **RL Menu** (default **Right Shift + O**, or press **R** at one of your pens) and pick the **Herdsman** tab, between **Message Log** and **Settings**. It is part of your own-herd menu, so it isn't shown when you open the menu at an animal dealer.

In multiplayer you need the **trade animals** farm permission to create or edit tasks.

---

## How a task works

Every task has four parts:

- **Operation** (labeled **Task** in the menu) - the single job it does: Sell, Move, Buy, Castrate, Naming, AI, or Horse Care.
- **Filter** - a [saved filter](guide-saved-filters.md) that decides which animals qualify. (Naming tasks don't need one.)
- **Pens** - which of your husbandries the task looks at. A task with **no pens does nothing** - it never falls back to "all pens".
- **Settings** - the options for that operation (how many animals per day, a buy budget, a semen source, and so on), plus an on/off switch. Some operations have no options of their own - Horse Care just needs a filter and its pens - so this section only shows the on/off switch.

Each day the Herdsman runs tasks in a **fixed order**:

**Sell -> Move -> Buy -> Castrate -> Naming -> AI -> Horse Care**

So selling happens before buying - a "sell old cows, then buy young ones" pair does the sensible thing within a single day.

---

## The operations

- **Sell** - sells matching animals back to the dealer.
- **Move** - moves matching animals to another of your pens, or delivers them to a **butcher** (an Extended Production Point). Animals outside the butcher's accepted age range are skipped and reported.
- **Buy** - buys animals from the dealer into the chosen pen, up to a daily budget or count.
- **Castrate** - castrates matching males. Not available for chickens.
- **Naming** - gives unnamed animals names, either at random or alphabetically. No filter needed.
- **AI** - artificially inseminates matching females using stored semen (from a source you choose, or any available).
- **Horse Care** - exercises and grooms matching horses every day, so their Daily Riding and Cleanliness stay up and they hold their sale value. Only available for horse pens.

---

## Setting up a task

1. **New** - creates a draft task to start from (a disabled Sell task).
2. **Operation** - pick the job you want. If you change the job later, a filter the new job can't use is unbound for you - a chicken-only filter on Castrate, or a filter tied to a non-horse animal on Horse Care - along with any pens that no longer suit the job. A filter that isn't tied to one animal type is kept. Note that if the task is already **enabled**, the whole change is discarded when you leave the menu: disable it first, repair it, then switch it back on.
3. **Filter** - open the filter picker and choose a saved filter. Only filters that suit the operation are offered, so it helps to [build the filter first](guide-saved-filters.md).
4. **Pens** - open the pen picker and select one or more husbandries. Only pens matching the filter's animal type are offered.
5. **Settings** - set the per-operation options.
6. **Enable** - switch the task on. A task needs at least one pen before it can be enabled.

You can **Duplicate** a task as a starting point for another, or **Delete** one (with a confirmation).

---

## Good to know

- **No pens, no action.** A task with no pens selected does nothing - this is deliberate, so a half-finished task can't run wild across your whole farm.
- **Order matters.** Because Sell runs before Buy, a sell-then-buy pair refreshes a pen in one day rather than two.
- **Start narrow, then watch.** Test a new task with a tight filter and check the **Message Log** to see exactly what the Herdsman did before widening it.
- **The filter is the whole game.** The Herdsman only ever touches animals the filter matches - a well-built filter is what keeps automation safe.
- **Horse Care needs a filter like any other task.** Only Naming works without one, so a Horse Care task with no filter selected sits idle. A filter that simply matches every horse is a perfectly good starting point.
- **Horse Care bills every horse, every day.** The wage is per horse per day and there is no cap and no upper limit on herd size, so a large stable keeps paying for as long as the task is enabled - and it keeps paying whether or not you ever sell the horse. The payoff comes when you sell, so it suits a stable you trade from rather than one you only breed in. We recommend selling a horse manually after a full riding session to sell at the highest possible price - selling automatically via the Herdsman forgoes the riding share of the care bonus for that day, though the fitness and cleanliness built up by earlier care still count.

---

## Multiplayer

Tasks are shared across the server and run on the host or dedicated server. You need the **trade animals** permission to edit them, and the results sync to every player.
