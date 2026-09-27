# Everything WoW Companion 0.2.3

The Everything WoW Companion records what Blizzard's API does not publish: where an NPC stands, where a quest starts, what a vendor sells, what a kill dropped, and what your own character is wearing. An addon cannot send anything over the network, so the Companion writes what it sees to its saved variables file and you upload that file when you feel like it. Nothing leaves your computer until you choose to upload it.

This is version 0.2.3. It is free and open source under the MIT license.

## Changes

**0.2.3** sends the `forever` version key for a Forever session. The site's `versions` table has had its `forever` row enabled since 24 September 2026, so the asymmetry 0.2.1 documented is closed.

- **Forever recordings land under Forever.** `EW.VersionKey`, the key written to `db.version`, now answers `forever` whenever `EW.Client` reads as `forever`, that is, a version string of major 1 and minor 60 or above, whatever project id the client carries. The upload's own field therefore reads `forever` for the owner's build 1.60.1 session, and its recordings land in the Forever database rather than Retail's. Retail, Classic Era, Hardcore, and a client the table cannot place answer exactly as they did in 0.2.2.
- **`db.client` still rides beside it.** It carries the client this addon detected, now the same key as `db.version` for a Forever session, and `/ewow status`'s `game` line still reads it. Nothing else changed: the capability table, the probe, the forbidden handler, and every recorder are exactly as 0.2.2 shipped them.

**0.2.2** settles the Forever capability profile on the owner's own `/ewow probe` transcript, run against 0.2.1 on build 1.60.1: `NAME_PLATE_UNIT_ADDED`, `UPDATE_MOUSEOVER_UNIT`, and `PLAYER_TARGET_CHANGED` came back allowed, `COMBAT_LOG_EVENT_UNFILTERED` and `AUCTION_ITEM_LIST_UPDATE` came back refused, and the owner's own `/ewow cap worldCursor on` and `/ewow cap unitGuid on` afterward raised no alert. The same transcript also showed a second alert the probe itself caused: `ADDON_ACTION_FORBIDDEN` reported for `EverythingWoWFrame:UnregisterEvent()`, which turned every restricted capability off, worldCursor and unitGuid included, on the strength of a refusal 0.2.1 could not place.

- **The Forever profile.** `worldCursor` and `unitGuid` now default on for Forever, `combatLog` stays off, and a new `auction` capability, gating `AUCTION_ITEM_LIST_UPDATE` and this addon's own auction API calls, defaults off too. Retail's `auction` capability is on, and Classic Era and Hardcore keep their long standing unrestricted behavior, where Auction.lua's own scan is the only way the auction house gets recorded at all.
- **A refused registration is never followed by an unregister call.** The probe used to call `UnregisterEvent` unconditionally after every attempt, including a refused one, but a refused registration was never actually registered, so there was nothing to unregister, and the owner's own build 1.60.1 session proved that calling it anyway is itself forbidden. The probe now skips that call entirely when the registration was refused.
- **An UnregisterEvent refusal is attributed to the exact event, the same as a RegisterEvent refusal.** Two bugs combined to make 0.2.1's fallback the wrong one: `EW.lastRegisterAttempt` was already cleared by the time the unconditional unregister call ran, and `NamesRegisterEvent`'s substring check for `"RegisterEvent"` does not match `"UnregisterEvent"`, which spells its own `register` with a lowercase `r`. `EW.UnregisterEvent`, a new counterpart to `EW.RegisterEvent`, sets `EW.lastRegisterAttempt` around the client call, and `NamesRegisterEvent` now checks for both spellings, so a refusal there turns off only the one capability that event feeds.
- **The probe's tally counts every event exactly once**, allowed or refused, whether or not its own cleanup call is refused too.
- **Loot with combatLog off.** On a client without the combat log, such as Forever, this recorder's kill counter never runs, so a kill that drops nothing is never recorded there; a kill that drops something is unaffected, because it is read off the loot window's own source guid rather than off anything the combat log tracked. Separately, a loot window whose source guid cannot be placed at all, on any client, no longer loses its items: the observation is still recorded, with its subject and its payload's `source_type` marked `"unknown"` rather than the items being thrown away.
- **The idle auction recorder says so.** Where `auction` is off, Auction.lua registers no listener and instead announces once, at the next `PLAYER_ENTERING_WORLD`, that auction recording is off for the client rather than staying silently idle.

**0.2.1** answers what running 0.2.0 in World of Warcraft: Forever actually showed, pasted back by the owner as `/ewow status`: `game retail` and `client retail (interface 16001, build 1.60.1)`, with `last forbidden action: ADDON_ACTION_FORBIDDEN for EverythingWoWFrame:RegisterEvent() on build 1.60.1 (client retail)` and every one of the three capabilities off.

- **Forever detected off the version string first, whatever the project id.** That paste proved 0.2.0's own assumption wrong: Forever's `WOW_PROJECT_ID` is the mainline id, the same one Retail reports, not the Classic id 0.2.0 expected it to share. 0.2.0 checked the project id before the version string, so a build 1.60.1 session carrying the mainline id read as Retail and switched every capability back on, which is what actually let `RegisterEvent()` reach the client and get refused. 0.2.1 checks the version string, major 1 and minor 60 or higher, before `WOW_PROJECT_ID` is even asked, so this exact session now reads as `forever` and every capability starts off. An unreadable version string still reads as `unknown`, the same restrictive row. `/ewow status` now prints `game <client key>` on its first line rather than the upload's own version key, so a person reads the client this addon actually found rather than the separate key described below.
- **A RegisterEvent refusal is attributed to the event, not to nothing.** The reported function, `EverythingWoWFrame:RegisterEvent()`, is the frame method every recorder's registration goes through, so it was never one of the specific calls `FUNCTION_CAPABILITY` could place, and 0.2.0's handler read that as a report it could not place at all and turned every capability off. `EW.RegisterEvent` now records the event it is mid call on, and a refusal naming `RegisterEvent` is looked up against which capability that event feeds instead, so only that capability turns off. An event that feeds no gated capability, or a report this still cannot place, keeps 0.2.0's fallback: every capability off for the session.
- **`/ewow probe`.** Attempts every event a recorder in this addon registers, one at a time through the same attribution path, undoing each attempt immediately, and prints one line per event: allowed or refused. The result is also written to the saved file under `db.probe`, so an upload carries it once it exists, since the payload schema already tolerates a field it does not read. This replaces waiting for gameplay to trip each restricted call in turn.
- **`/ewow cap <name> on|off`.** Flips one capability for the session, so once the probe has said which events the client allows, the tooltip hook or the GUID path can be turned on and tested on its own without waiting for a code change.
- **The upload's version key is unchanged, and that is now a documented asymmetry rather than an assumed one.** The site's `versions` table has no enabled row for `forever` yet, so `EW.VersionKey`, the key written to `db.version`, still has no `forever` branch and still sends whatever it sent before: `retail` for a session carrying the mainline project id, which is what the owner's own Forever session actually carries. `db.client`, a new field beside `db.version`, carries this addon's own corrected client key instead, `forever` for that same session, and rides along because `readCompanionFile` in the site's `read.ts` reads specific keys off the saved table and ignores any others rather than rejecting them. `/ewow status` reads `db.client` for its `game` line for the same reason.

**0.2.0** answers the World of Warcraft: Forever compatibility block reported on 18 September 2026: an alert reading "EverythingWoW has been blocked from an action only available to the Blizzard UI. You can disable this addon and reload the UI," on build 1.60.1, naming no function.

- **A capability table per client.** The addon now reads `EW.Client` from `WOW_PROJECT_ID`, the interface number, and the version string as soon as `Core.lua` loads, rather than assuming every call works until it errors. Forever cannot be told apart from Classic Era by project id alone, since it is expected to answer with the same one, so the client key is read off the version string's major and minor instead: 1.14 and 1.15 read as Classic Era, 1.60 and up read as Forever. A client the table cannot place reads as Forever too, the most restrictive row rather than the most permissive one.
- **Three capabilities gated, not merely wrapped.** The world cursor tooltip hook (`C_TooltipInfo.GetWorldCursor`, installed inside Blizzard's own tooltip handler), the GUID reader that identifies an NPC or an object, and the combat log listener each sit behind a named capability, and every one of the three defaults off on Forever until an owner's paste proves it safe. Where a capability is off, the restricted call is never made at all: the tooltip hook is never installed, the combat log listener is never registered, and the GUID reader returns nothing rather than pattern matching or comparing what a secret value system may not allow either. The existing `pcall` guards stay in place, because they still catch a changed signature; they were never going to catch this alert, and they still are not what stops it.
- **Forbidden action reporting.** `ADDON_ACTION_FORBIDDEN` and `ADDON_ACTION_BLOCKED` are now handled when either names this addon: the reported function (or, as on the owner's own Forever alert, the absence of one), the client, and a timestamp are written into the saved file, and the matching capability, or every capability where no function is named, is turned off for the rest of the session. `/ewow status` now prints the client, the capability table, and the last forbidden action recorded.
- **No table of contents change yet.** Both `## Interface` numbers are unchanged, and no third table of contents file is added. The suffix a Forever client reads is still unproven, and a guessed interface number is exactly the kind of guess this release is against.

**0.1.1** fixes what the first live test on a Retail client showed.

- **Vendor prices.** Retail no longer has the `GetMerchantItemInfo` global; the merchant frame answers through `C_MerchantFrame.GetItemInfo` instead. 0.1.0 read only the global, so on Retail every vendor item was written with its id and no price at all. Both shapes are read now, and an item bought with a currency records that currency's id and amount beside a copper price of zero rather than looking free.
- **One snapshot a session.** 0.1.0 took its login snapshot on a fixed ten second timer, before the client had loaded the currency list, and could take a second one minutes later for no gain. The login snapshot now waits until the client answers with gear and currencies, and after that a snapshot is written only on `/ewow snapshot`, or after an hour when the gear or the level has changed.
- **Honest counters.** 0.1.0 counted everything it did not write as `skipped`, which reported 802 losses in a few minutes when almost nothing had been lost. `/ewow status` now separates `skipped` (a subject the addon could not place, the only real loss) from `deduped` (a sighting the five minute window already holds) and `ignored` (another player, a pet, a vehicle, a tooltip that is not a world object), and prints each one by reason.

**0.1.0** was the first release.

## Installing

1. Close World of Warcraft.
2. Copy the `EverythingWoW` folder from a release package into your addons folder, or clone this repository into a folder of that name there:
   - Windows: `C:\Program Files (x86)\World of Warcraft\_retail_\Interface\AddOns\EverythingWoW`
   - macOS: `/Applications/World of Warcraft/_retail_/Interface/AddOns/EverythingWoW`
   - On Classic Era, replace `_retail_` with `_classic_era_`.
3. Start the game, open the character select screen, click AddOns, and make sure Everything WoW Companion is checked.
4. Play. Type `/ewow status` at any time to see what has been recorded.

The folder must be named `EverythingWoW`, because the game looks for a table of contents file with the same name as its folder.

## Which game versions this supports

The addon ships two tables of contents. `EverythingWoW.toc` carries `## Interface: 120100` for Retail and `EverythingWoW_Vanilla.toc` carries `## Interface: 11509` for Classic Era and Hardcore. Current clients support both this separate suffixed file and the single file `## Interface-Vanilla:` directive; the separate file is used here because it is also read by older Classic Era builds, which the directive is not, and because a wrong interface number in one file cannot then make the other look out of date.

Blizzard has published no `WOW_PROJECT_ID` value of its own for Forever, and the owner's own build 1.60.1 session reads back the mainline id, the same one Retail reports, rather than the Classic id this addon first expected Forever to share. So the addon tells Forever apart from every other client by its version string alone, 1.60 and up rather than 1.14 or 1.15, checked before `WOW_PROJECT_ID` is even asked since 0.2.1, and locks down every restricted call there until it is proven safe, whatever `WOW_PROJECT_ID` says. Since 0.2.3 that same reading decides the upload's attribution: a Forever client is recorded as `forever` in `db.version`, the field the site's upload path reads and validates against its own `versions` table, whose `forever` row has been enabled since 24 September 2026. 0.2.1 and 0.2.2 recorded a Forever session as `retail` there while that row did not exist. `db.client` carries this addon's own detected key beside `db.version`, and `/ewow status`'s `game` line reads it.

## Uploading

The file lives here, where `<ACCOUNT>` is your Battle.net account folder:

- Windows: `C:\Program Files (x86)\World of Warcraft\_retail_\WTF\Account\<ACCOUNT>\SavedVariables\EverythingWoW.lua`
- macOS: `/Applications/World of Warcraft/_retail_/WTF/Account/<ACCOUNT>/SavedVariables/EverythingWoW.lua`

The game writes it when you log out or reload the interface, so log out first. Then open <https://everythingwow.com/addons/companion/upload>, drag the file onto the page, and read the summary it shows you before you send anything. The file is read in your browser; nothing is sent until you press Upload. Sign in first if you want your uploads credited to you, or upload without signing in.

`/ewow path` prints the folder in game.

## Source and Releases

The source lives at <https://github.com/DustinSartoris/everythingwow-addon>. A release is a tag on that repository, `v` followed by the version both tables of contents carry, and each tag is packaged into the `EverythingWoW` folder the stores offer: on CurseForge at <https://www.curseforge.com/wow/addons/everything-wow-companion> and on Wago, whose address is added here when the project exists. The `X-Curse-Project-ID` and `X-Wago-ID` lines are added to both tables of contents when those ids are known.

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
| Auction rows | On Classic Era and Hardcore only, from a search you ran yourself: item, quantity, and unit price. The addon never runs a scan of its own and never sends a query to Blizzard. Retail is skipped entirely, because Blizzard's own auction API is what the site reads there. Refused outright on Forever as of the owner's own probe, so the `auction` capability is off there and this recorder stays idle. |

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
| `/ewow status` | The client detected, the capability table, the last forbidden action reported, the counts per kind, the number dropped, and the skipped, deduped, and ignored counts with the reason for each, plus the game version and the patch. |
| `/ewow clear` | Throws away everything recorded so far. Start here if you would rather not upload something. |
| `/ewow snapshot` | Records your character snapshot now rather than waiting for the next login. |
| `/ewow path` | Prints where the file is written. |
| `/ewow probe` | Attempts every event this addon registers, one at a time, and prints whether the client allowed or refused each one. Saved to the file under `db.probe` as well. |
| `/ewow cap <name> on\|off` | Flips one capability, `worldCursor`, `unitGuid`, `combatLog`, or `auction`, on or off for the rest of the session, so a capability the probe found safe can be tested on its own. Does not persist past a reload. |

## Limits of this version

The addon is honest about what it cannot see, because a guessed id would become a map pin on the site.

- A game object the client shows only as a tooltip has no documented id on Classic Era, and `GameTooltip:GetOwner()` names the frame rather than the thing in the world. Where no id can be read, nothing is written and the tooltip is counted under `ignored` in `/ewow status`. Only a subject that has an id the client will not place counts as `skipped`, because only that is a loss.
- Vendor and quest giver flags on an NPC sighting are not recorded. Nothing on a nameplate says whether a creature sells or gives quests, so those facts come from the vendor and quest records instead.
- Quest objective locations, trainer lists, and flight paths are part of the file contract and are not recorded in 0.1.0.
- The buffer holds 5,000 observations. Past that the oldest are dropped and counted, which is the same number the upload page sends in one file, so upload and then `/ewow clear` if you play a great deal between uploads.

## Developing and testing

The recorders are plain Lua with no libraries. `tests/run.lua` loads the real addon files against a small stand in for the client, fires the events, asserts the saved shape, and writes a file the way the game writes one. The Everything WoW worker's `addon/tests/check-file.mjs`, which stays with the site's code because it reads the site's parser out of the application repository, then reads that file with the site's own parser and with the worker's aggregation readers, so the file is proved against both ends rather than against a description of them. Since 0.2.0, `tests/run.lua` also loads the addon fresh against four simulated clients, Retail, Classic Era, Forever, and one the capability table does not recognize, and asserts that each restricted capability reads correctly for its client; since 0.2.2, Forever's own profile has `worldCursor` and `unitGuid` on, so firing one of those gated events there is asserted to write an observation rather than nothing, while `combatLog` and `auction` stay off and their events are asserted to write nothing and raise no error. Since 0.2.1, `stub.state.forbiddenEvents` makes the stand in client refuse one named event's registration the way the owner's own Forever session refused `RegisterEvent()`, which the tests use to prove that a Forever session carrying the mainline project id still reads as `forever`, that the refusal is attributed to the exact event rather than to every capability, and that `/ewow probe` prints and saves one line per event. Since 0.2.2, `stub.state.forbiddenUnregisterEvents` and `stub.state.unregisterAttempts` reproduce the owner's own second alert, naming `EverythingWoWFrame:UnregisterEvent()`, and the tests use them to prove a refused registration is never followed by an unregister call at all and that a refused unregister is still attributed to its own event rather than falling back to every capability off.

```
lua5.4 tests/run.lua /tmp/EverythingWoW.lua
```

The run writes a second file from a Forever session beside the first, `/tmp/EverythingWoW-forever.lua`, and the worker's `node addon/tests/check-file.mjs <file>` reads either one.

The worker also keeps `addon/tests/fixtures/live-0.1.0.lua`, a file a live Retail client wrote with 0.1.0, with the character renamed and everything else left as it stood. It is the evidence for the three fixes above, so no later version may quietly write a file that looks like it again. Running `node addon/tests/check-file.mjs addon/tests/fixtures/live-0.1.0.lua` in the worker shows what the site made of it: all 28 observations accepted, none refused, and the vendor row the only thing missing a price.
