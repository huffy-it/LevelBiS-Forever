# LevelBiS

Addon for **World of Warcraft TBC Anniversary (2.5.x client)** that tells you
which gear to get as you level from 1 to 70.

- It looks at what you have equipped and, slot by slot, suggests something
  better that you can actually equip and obtain.
- It tells you **where to start**: the slot where you gain the most.
- It works offline and without hand-made BiS lists: it scores every item with
  the stat weights of your spec.

The interface is in English, and in Spanish on Spanish clients (esES/esMX).

Download: [CurseForge](https://www.curseforge.com/wow/addons/levelbis) ·
[GitHub releases](https://github.com/huffy-it/LevelBiS/releases)

Current version: `0.20.1`.

> **Work in progress.** LevelBiS is under constant development and you will run
> into bugs: odd recommendations, missing sources, text that doesn't fit. If
> something looks wrong, `/lbis errors` lists what the addon caught; please report
> it on the repository's Issues page along with your class, spec and level.

---

## Installation

1. Copy the `LevelBiS/` folder into `World of Warcraft/_classic_/Interface/AddOns/`.
2. Log in and type `/lbis` (or click the minimap button).

If the addon shows up as "out of date", enable "Load out of date AddOns" on the
character selection screen.

---

## Getting started

Open the window with `/lbis`. You will see your 17 equipment slots in three
groups (armor, accessories and weapons):

| Column | What it means |
|---|---|
| **Equipped** | What you are wearing and its score. |
| **Upgrade available** | Gray bar: what you already have. Teal segment: what you would gain. |
| **Recommended** | The best item you can get, in its quality color. On the right, where it comes from (`Dun`, `Raid`, `Qst`, `Vnd`, `Crf`, `PvP`, `Wld`) and how it binds (`BoP`, `BoE`, `BoU`). |
| **Gain** | How much that slot improves, as a percentage. "up to date" means you already have the best. |

The line at the top and the teal-bordered row (**Start here**) mark the slot
that adds the most points. Note that the highest percentage is not always the
biggest upgrade, because each slot starts from a different score.

### Clicking a recommended item

- **Hover:** shows its tooltip.
- **Click:** opens the row's details (click again to close them).
- **Shift-click:** links the item in chat.
- **Ctrl-click:** tries it on in the dressing room.
- **With the Auction House open:** click searches for it there, and Alt-click
  opens the details.

### The details

Click a row to see:

- which item it replaces and which stats you gain (teal) or lose (red);
- where it comes from and from what level you can go get it;
- why it scores that way and how long it will stay useful;
- the price you saw on the Auction House, if any;
- the **best alternative with no random roll** and how much you lose by picking
  it, in case you don't want to chase a specific suffix ("of the Bear",
  "of the Tiger"...).

---

## Tabs

- **Gear:** the slot list described above.
- **Dungeons:** "Which dungeon should I run?" It suggests the dungeons that give
  you the most upgrades for your level and filters.
- **Consumables:** the flask or elixirs, food and potions that suit you best,
  calculated with your weights.

---

## Filters

Click **Show filters** to see them. A summary of what is active always appears
below, and **Reset filters** goes back to the defaults.

**Checkboxes**

| Checkbox | Default | What it does |
|---|---|---|
| No raid | On | Hides what only drops in raids. |
| Instances | Off | Only drops and vendors from dungeons or raids. |
| Quests | Off | Only quest rewards. Can be combined with Instances. |
| My professions | On | Hides what needs a profession you don't have. |
| Reachable | On | Only what you can really get: high enough level, enough reputation, quests you haven't done yet, and no seasonal events (Brewfest, Hallow's End...). |

**Buttons** (each click moves to the next option)

| Button | Options |
|---|---|
| Rolls | **Best**: counts the best possible roll of random items · **Ignore**: counts only what is guaranteed · **Exclude**: hides random items. |
| Auction House | **Include** · **Exclude**: hides what can be bought on the Auction House · **Only**: only what can be bought. |
| Order | **Slot** · **Upgrade**: from largest to smallest gain, with a line where 70% of your upgrade adds up · **Gold**: best return per coin, based on the prices you saw. |

**Level row**

- `<` `>` and **Current**: pick the level you want the recommendation for.
- **Goal: leveling / level 70**: level 70 mode includes raids, heroics and the
  open phase. When you go back to "leveling" your filters come back.
- **Dungeons: all / normal / heroic**.
- **Phase**: up to which server phase content counts. By default, the current
  phase.

---

## Weights panel

The **Weights** button (top right) opens the weights editor for your spec. There
you can change how much each stat is worth, import or export Pawn scales, and go
back to the preset.

It also has four settings:

- **Level weights** (on): ratings such as hit or crit are worth more at low
  levels; this checkbox takes that into account.
- **ilvl cap**: hides items with an item level far above what is usual.
- **Hit cap (70)**: at level 70, hit beyond the cap is not valued.
- **Bag alerts**: warns you in chat if something in your bags upgrades a slot
  (only while the window is open).

---

## While you play

- **Quests:** when you accept or turn in a quest with several rewards, the chat
  tells you which one to pick. If none is an upgrade, it suggests the one that
  sells for the most.
- **Group loot:** when you roll on an item, it tells you whether Need or Greed
  makes sense.
- **Leveling up:** the chat tells you about the upgrades that open up.
- **Tooltips:** any item shows how much it would improve your gear.
- **Auction House:** the addon remembers the prices you see when you search
  (for each roll separately) for 30 days. It never searches on its own.

---

## Commands

| Command | What it does |
|---|---|
| `/lbis` | Opens or closes the window. |
| `/lbis help` | Help and slot names. |
| `/lbis summary` | Summary of the 17 slots in chat. |
| `/lbis slot <slot>` | The best options for a slot. |
| `/lbis spec [name\|auto]` | View or set your spec. |
| `/lbis level [n\|next]` | Change the target level. |
| `/lbis edit` | Open the weights editor. |
| `/lbis filter [name] [on\|off]` | View or change filters, including those without a checkbox (My armor, My faction, No PvP). |
| `/lbis sort [slot\|upgrade\|gold]` | Change the row order. |
| `/lbis consumables` | Recommended consumables in chat. |
| `/lbis quest` | Which reward to pick for the selected quest. |
| `/lbis bags [on\|off]`, `/lbis equip` | Bag alerts, and equip the last upgrade you were alerted about. |
| `/lbis rolls [on\|off]` | Advice when rolling on loot. |
| `/lbis profs sim` | Which profession would give you the most gear. |
| `/lbis phase [1-5\|all\|auto]` | Server phase. |
| `/lbis goal [70\|leveling]` | Switch between leveling and level 70. |
| `/lbis access` | What the addon reads about your reputation and quests. |
| `/lbis import <scale>`, `/lbis export` | Import or export a Pawn scale. |
| `/lbis explain <itemID>` | Score breakdown for an item. |
| `/lbis errors` | Errors logged by the addon. |

Slots: `head neck shoulder chest waist legs feet wrist hands finger1 finger2
trinket1 trinket2 back mainhand offhand ranged`.

---

## Good to know

- **The score is not DPS.** It is the sum of stats according to your spec's
  weights. It is for comparing items, not for simulating combat.
- **Gems and enchants you already have on your gear don't count**, neither in
  what you wear nor in what is recommended. **Sockets do:** an item of item level
  100 or higher is valued as if every socket held the best gem for your weights
  (plus the socket bonus, when it is worth it), the way Pawn does, and the same
  goes for what you are wearing. From item level 151 on, epic gems are used;
  below that, rare ones. Meta gems count only for their stat, not their special
  effect. It is an assumption: the addon doesn't know which gems you have or
  which ones you can afford. `/lbis explain <id>` shows that part on a separate
  line ("Sockets").
- **Special effects** (procs and on-use effects) are described but not scored:
  there is no reliable way to put a number on them.
- **Loot drop chances** come from cmangos and are approximate.
- **Seasonal events** are not detected: during a holiday, turn off "Reachable"
  to see their items.
- **Reachable** checks level, reputation and quests, but not keys, quest chains
  or attunements.

---

## Data

The database includes 11,544 items generated from the open data of
[cmangos tbc-db](https://github.com/cmangos/tbc-db) (TBC 2.4.3) and the client
tables published on [wago.tools](https://wago.tools). Identifiers, stats and drop chances are never
made up: if a piece of data is not in the source, it is left out.

---

## License

GPL-3.0. See [LICENSE](LICENSE). The item data is derived from
[cmangos tbc-db](https://github.com/cmangos/tbc-db), which is also GPL-3.0.
