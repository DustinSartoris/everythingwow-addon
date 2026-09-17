# Everything WoW Companion 0.1.1

The Everything WoW Companion records what Blizzard's API does not publish: where an NPC stands, where a quest starts, what a vendor sells, what a kill dropped, and what your own character is wearing. An addon cannot send anything over the network, so the Companion writes what it sees to its saved variables file and you upload that file when you feel like it. Nothing leaves your computer until you choose to upload it.

This is version 0.1.1. It is free and open source under the MIT license.

## Changes

**0.1.1** fixes what the first live test on a Retail client showed.

- **Vendor prices.** Retail no longer has the `GetMerchantItemInfo` global; the merchant frame answers through `C_MerchantFrame.GetItemInfo` instead. 0.1.0 read only the global, so on Retail every vendor item was written with its id and no price at all. Both shapes are read now, and an item bought with a currency records that currency's id and amount beside a copper price of zero rather than looking free.
- **One snapshot a session.** 0.1.0 took its login snapshot on a fixed ten second timer, before the client had loaded the currency list, and could take a second one minutes later for no gain. The login snapshot now waits until the client answers with gear and currencies, and after that a snapshot is written only on `/ewow snapshot`, or after an hour when the gear or the level has changed.
- **Honest counters.** 0.1.0 counted everything it did not write as `skipped`, which reported 802 losses in a few minutes when almost nothing had been lost. `/ewow status` now separates `skipped` (a subject the addon could not place, the only real loss) from `deduped` (a sighting the five minute window already holds) and `ignored` (another player, a pet, a vehicle, a tooltip that is not a world object), and prints each one by reason.

**0.1.0** was the first release.

## Installing

1. Close World of Warcraft.
2. Copy the `EverythingWoW` folder into your addons folder:
   - Windows: `C:\Program Files (x86)\World of Warcraft\_retail_\Interface\AddOns\EverythingWoW`
   - macOS: `/Applications/World of Warcraft/_retail_/Interface/AddOns/EverythingWoW`
   - On Classic Era, replace `_retail_` with `_classic_era_`.
3. Start the game, open the character select screen, click AddOns, and make sure Everything WoW Companion is checked.
4. Play. Type `/ewow status` at any time to see what has been recorded.

The folder must be named `EverythingWoW`, because the game looks for a table of contents file with the same name as its folder.

## Which game versions this supports

The addon ships two tables of contents. `EverythingWoW.toc` carries `## Interface: 120100` for Retail and `EverythingWoW_Vanilla.toc` carries `## Interface: 11509` for Classic Era and Hardcore. Current clients support both this separate suffixed file and the single file `## Interface-Vanilla:` directive; the separate file is used here because it is also read by older Classic Era builds, which the directive is not, and because a wrong interface number in one file cannot then make the other look out of date.

Forever is not detectable from inside the game. Blizzard has published no `WOW_PROJECT_ID` value for it, so a Forever client is recorded as Classic Era until one exists. When Blizzard ships that value, one line in `Core.lua` changes and nothing else does.

## Uploading

The file lives here, where `<ACCOUNT>` is your Battle.net account folder:

- Windows: `C:\Program Files (x86)\World of Warcraft\_retail_\WTF\Account\<ACCOUNT>\SavedVariables\EverythingWoW.lua`
- macOS: `/Applications/World of Warcraft/_retail_/WTF/Account/<ACCOUNT>/SavedVariables/EverythingWoW.lua`

The game writes it when you log out or reload the interface, so log out first. Then open <https://everythingwow.com/addons/companion/upload>, drag the file onto the page, and read the summary it shows you before you send anything. The file is read in your browser; nothing is sent until you press Upload. Sign in first if you want your uploads credited to you, or upload without signing in.

`/ewow path` prints the folder in game.

## What is recorded

| What | When |
|---|---|
| NPC sightings | A nameplate appears, you mouse over a creature, or you target one. The creature id, name, level, reaction, map, and position. |
| Rare sightings | The same moments, where the creature is rare, rare elite, or a world boss. |
| Game objects and gathering nodes | When you loot the object, which is the one moment its id can be read exactly. On Retail, also when the tooltip for the object under your cursor carries an id. |
| Quests | When a quest is offered and when it is turned in: the quest id, the map and position, and the npc who gave or took it. |
| Vendors | When a merchant window opens: the vendor npc and up to 100 of its items, each with its price in copper, its stack size, and, where it is bought with something other than money, the currency id and how much of it the item costs. |
| Loot and kills | When a loot window opens: the source and the items, gold included. A kill your group made that nothing dropped from is recorded as an empty loot event, because a drop rate needs the kills that dropped nothing as much as the ones that did. |
| Your character | Once on login, after the client has loaded your gear and currencies, and on `/ewow snapshot`: your gear per slot, talents, professions, reputations, and currencies. After that, only when an hour has passed and your gear or your level has changed. |
| Auction rows | On Classic Era and Hardcore only, from a search you ran yourself: item, quantity, and unit price. The addon never runs a scan of its own and never sends a query to Blizzard. Retail is skipped entirely, because Blizzard's own auction API is what the site reads there. |

## What is never recorded

- No chat, of any channel, ever. Not say, not whisper, not guild, not party.
- No other player's name, level, guild, or gear. Other players' identifiers are used in memory to tell whether your group killed something and are never written to the file.
- No account data: no email address, no Battle.net tag, no payment information, no password. The addon cannot read them and does not look.
- No combat log. Combat logs come from the game's own `WoWCombatLog.txt` and have nothing to do with this addon.
- No auction seller names, although the client hands them to the addon. They are read past and thrown away.

The only character named in the file is your own. The snapshot carries your character's name and realm because it exists to fill in your own character page on the site, and that is the only place in the file a character name of any kind appears. The addon reads a name from a unit in one other place, the creature on a nameplate, a mouseover, or your target, and it stops before reading it if the unit is a player, a pet, a guardian, or a vehicle, so a person's name can never reach the file through it.

The map id and the coordinates are the client's own: `C_Map.GetBestMapForUnit("player")` gives the uiMapID of the map you are standing on and `C_Map.GetPlayerMapPosition` gives your place on it as two fractions from 0 to 1 with the origin at the top left. That uiMapID is the identifier the site's zone maps and pins are keyed by, so nothing is converted anywhere.

## Slash commands

| Command | What it does |
|---|---|
| `/ewow status` | The counts per kind, the number dropped, and the skipped, deduped, and ignored counts with the reason for each, plus the game version and the patch. |
| `/ewow clear` | Throws away everything recorded so far. Start here if you would rather not upload something. |
| `/ewow snapshot` | Records your character snapshot now rather than waiting for the next login. |
| `/ewow path` | Prints where the file is written. |

## Limits of this version

The addon is honest about what it cannot see, because a guessed id would become a map pin on the site.

- A game object the client shows only as a tooltip has no documented id on Classic Era, and `GameTooltip:GetOwner()` names the frame rather than the thing in the world. Where no id can be read, nothing is written and the tooltip is counted under `ignored` in `/ewow status`. Only a subject that has an id the client will not place counts as `skipped`, because only that is a loss.
- Vendor and quest giver flags on an NPC sighting are not recorded. Nothing on a nameplate says whether a creature sells or gives quests, so those facts come from the vendor and quest records instead.
- Quest objective locations, trainer lists, and flight paths are part of the file contract and are not recorded in 0.1.0.
- The buffer holds 5,000 observations. Past that the oldest are dropped and counted, which is the same number the upload page sends in one file, so upload and then `/ewow clear` if you play a great deal between uploads.

## Developing and testing

The recorders are plain Lua with no libraries. `addon/tests/run.lua` loads the real addon files against a small stand in for the client, fires the events, asserts the saved shape, and writes a file the way the game writes one. `addon/tests/check-file.mjs` then reads that file with the site's own parser and with the worker's aggregation readers, so the file is proved against both ends rather than against a description of them.

```
lua5.4 addon/tests/run.lua /tmp/EverythingWoW.lua
node addon/tests/check-file.mjs /tmp/EverythingWoW.lua
```

`addon/tests/fixtures/live-0.1.0.lua` is a file a live Retail client wrote with 0.1.0, with the character renamed and everything else left as it stood. It is the evidence for the three fixes above and the tests assert its shape, so no later version may quietly write a file that looks like it again. Running `node addon/tests/check-file.mjs addon/tests/fixtures/live-0.1.0.lua` shows what the site made of it: all 28 observations accepted, none refused, and the vendor row the only thing missing a price.
