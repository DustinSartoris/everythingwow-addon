# Everything WoW Companion 0.1.0

The Everything WoW Companion records what Blizzard's API does not publish: where an NPC stands, where a quest starts, what a vendor sells, what a kill dropped, and what your own character is wearing. An addon cannot send anything over the network, so the Companion writes what it sees to its saved variables file and you upload that file when you feel like it. Nothing leaves your computer until you choose to upload it.

This is version 0.1.0, the first release. It is free and open source under the MIT license.

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
| Vendors | When a merchant window opens: the vendor npc and up to 100 of its items with prices in copper and the currency where an item costs something other than money. |
| Loot and kills | When a loot window opens: the source and the items, gold included. A kill your group made that nothing dropped from is recorded as an empty loot event, because a drop rate needs the kills that dropped nothing as much as the ones that did. |
| Your character | On login and on `/ewow snapshot`: your gear per slot, talents, professions, reputations, and currencies. |
| Auction rows | On Classic Era and Hardcore only, from a search you ran yourself: item, quantity, and unit price. The addon never runs a scan of its own and never sends a query to Blizzard. Retail is skipped entirely, because Blizzard's own auction API is what the site reads there. |

## What is never recorded

- No chat, of any channel, ever. Not say, not whisper, not guild, not party.
- No other player's name, level, guild, or gear. Other players' identifiers are used in memory to tell whether your group killed something and are never written to the file.
- No account data: no email address, no Battle.net tag, no payment information, no password. The addon cannot read them and does not look.
- No combat log. Combat logs come from the game's own `WoWCombatLog.txt` and have nothing to do with this addon.
- No auction seller names, although the client hands them to the addon. They are read past and thrown away.

The only character named in the file is your own, because the snapshot exists to fill in your own character page on the site.

## Slash commands

| Command | What it does |
|---|---|
| `/ewow status` | The counts per kind, the number dropped, the number skipped, the game version, and the patch. |
| `/ewow clear` | Throws away everything recorded so far. Start here if you would rather not upload something. |
| `/ewow snapshot` | Records your character snapshot now rather than waiting for the next login. |
| `/ewow path` | Prints where the file is written. |

## Limits of this version

The addon is honest about what it cannot see, because a guessed id would become a map pin on the site.

- A game object the client shows only as a tooltip has no documented id on Classic Era, and `GameTooltip:GetOwner()` names the frame rather than the thing in the world. Where no id can be read, nothing is written and the sighting is counted under `skipped` in `/ewow status`.
- Vendor and quest giver flags on an NPC sighting are not recorded. Nothing on a nameplate says whether a creature sells or gives quests, so those facts come from the vendor and quest records instead.
- Quest objective locations, trainer lists, and flight paths are part of the file contract and are not recorded in 0.1.0.
- The buffer holds 5,000 observations. Past that the oldest are dropped and counted, which is the same number the upload page sends in one file, so upload and then `/ewow clear` if you play a great deal between uploads.

## Developing and testing

The recorders are plain Lua with no libraries. `addon/tests/run.lua` loads the real addon files against a small stand in for the client, fires the events, asserts the saved shape, and writes a file the way the game writes one. `addon/tests/check-file.mjs` then reads that file with the site's own parser and with the worker's aggregation readers, so the file is proved against both ends rather than against a description of them.

```
lua5.4 addon/tests/run.lua /tmp/EverythingWoW.lua
node addon/tests/check-file.mjs /tmp/EverythingWoW.lua
```
