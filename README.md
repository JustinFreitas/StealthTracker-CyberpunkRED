# StealthTracker for Cyberpunk RED (Fantasy Grounds Unity)

StealthTracker is a Fantasy Grounds Unity (FGU) extension designed for the **Cyberpunk RED** ruleset that automates the tracking of Stealth rolls in combat and resolves contested Stealth vs. Perception checks. 

This extension monitors PC and NPC Stealth rolls, records their stealth score as a Combat Tracker effect, and provides real-time notifications to the GM comparing current actor stealth to observer awareness. It also intercepts active Perception rolls and compares them directly against hiding combatants.

---

## Key Features

1. **Automated Stealth Tracking**:
   * When an actor rolls a **Stealth** check, the total result is automatically tracked as a Combat Tracker (CT) effect: `Stealth: [Total]`.
2. **Active Perception vs. Tracked Stealth**:
   * When a player or NPC rolls an active **Perception** check, the extension automatically compares the roll against all hiding enemies in the Combat Tracker and reports exactly who is spotted (e.g. `GUARD A SPOTTED Player B! (Perception roll 14 vs Stealth 12)`).
3. **Turn-Start Awareness Summaries**:
   * On an actor's turn start in the Combat Tracker, the extension evaluates their **Base Awareness** (`5 + INT + Perception Skill Level`) against all hiding opponents, notifying the GM in chat who they perceive or miss.
4. **Stealth Expiration**:
   * Attacking or performing loud/obvious actions will automatically expire the actor's active `Stealth` effect (configurable via options).
5. **NPC Skill Generation**:
   * Automatically ensures NPC sheets placed in the Combat Tracker have a valid Stealth skill configured (calculated from their DEX modifier if missing).

---

## Configuration Settings (GM Options)

StealthTracker adds a dedicated settings group under the GM Options window:

* **Player: Out of turn or combat Stealth**:
  * *None (Default)*: Stealth tracking is only active during combat on the actor's active turn.
  * *Turn / Turn and Combat*: Allows tracking out of turn or out of combat.
* **CT: Expire Stealth effect**:
  * *Attack and Round (Default)*: Expires stealth automatically on attacks or round ticks.
  * *Attack / None*: Expiration only on attack rolls, or manual management.
* **Player: Show Stealth info**:
  * *Effects (Default)*: Shows Stealth tracker effects to players.
  * *Chat and Effects / None*: Hides or reveals Stealth status messages to player client chats.
* **Chat: 'Actor Sees' verbosity**:
  * Configures which messages regarding detected/undetected actors are printed to the GM chat.

---

## Installation

> **Fantasy Grounds Unity (FGU) only.** This extension is not compatible with Fantasy Grounds Classic (FGC).

### Recommended: Fantasy Grounds Forge

Search for **"Cyberpunk RED StealthTracker"** in the Forge within Fantasy Grounds Unity and install it from there. Forge handles placing the extension in the correct folder and keeps it updated automatically.

### Manual / Developer Build

If you're building from source instead of using Forge:
1. Run [build-stealthtracker-zip.bat](file:///C:/code/StealthTracker-CyberpunkRED/build/build-stealthtracker-zip.bat) in the `/build` folder to package the files into a `.ext` file.
2. Move the generated `CyberpunkRED-StealthTracker.ext` file into your Fantasy Grounds Unity `extensions` directory.

Either way, once installed, enable **Cyberpunk RED StealthTracker** from the Extensions window when loading a Cyberpunk RED campaign.

---

## Changelog

### v1.7
* **Dice Tower & Secret Roll Privacy**: Stealth rolls made in the Dice Tower or secretly (`rRoll.bSecret` / `rRoll.bTower`, including critical continuation rolls and secret chat rolls dragged onto the CT) now automatically mark the resulting `Stealth: X` Combat Tracker effect as `GM Only` (`isgmonly = 1`) and suppress public chat announcements, even when `Player: Show Stealth info` is set to `Effects` or `Chat and Effects`.
* **Client-Side Visibility Option Lookup & Roll Initiation Hook**: Fixed `isPlayerStealthInfoDisabled()` on player clients by falling back to `DB.getValue("options.STEALTHTRACKER_VISIBILITY", "")`, and hooked `ActionsManager.performAction` alongside `ActionSkill.onRoll` so Stealth rolls are marked secret before dice are thrown when visibility is `None` or the actor is hidden.
* **Combat Tracker Chat-Roll Drag-and-Drop Fix**: Hooked `CombatDropManager.handleAnyDrop` directly in `onInit()` to ensure chat roll total drags reliably update CT stealth effects across modern CoreRPG, and detect Dice Tower / secret origins from description tags (`[TOWER]`, `[GM]`).
* **Active Perception Fixes**: Fixed `displayProcessActivePerception` to compare CT node paths via `getNodePathSafe()` (preventing hiding actors from spotting themselves due to distinct FGU userdata references), respect the `CT: Faction filter` option, and use `getActorDisplayNameSafe()` to protect unidentified NPC names.
* **Duplicate CT Actor & Stealth Effect Modifier Parity**: Added `getActiveDuplicateCTNodePath()` redirection for duplicate CT entries, updated `resolveTargetDuplicateCTNode()` to prefer the highest-Stealth duplicate, and wired `STEALTH_EFFECT_MODIFIERS` architecture (with chat breakdown formatting for modified Perception, e.g. `10 [15 - 5]`), ready for future custom gear/effect expansions.

### v1.6.2
* **Attack from Stealth Uncoupling**: Fixed attacker ambush notification being suppressed when the target was also hidden in stealth.
* **Safe Node Comparison**: Implemented path-based database node comparison (`getNodePathSafe()`) to avoid false out-of-turn warnings caused by distinct FGU userdata pointer references.
* **Turn Activation Guard & Error Isolation**: Guarded `CombatManager.requestActivation` against `/reload` recursion and wrapped NPC skill/stealth checks in `pcall` to prevent third-party NPC data anomalies from breaking turn advancement.
* **Modern CoreRPG Standards**: Updated host identification to check `Session.IsHost`, supported `CombatDropManager.registerLegacyDropCallback`, and switched to `DB.deleteNode()` for effect removals.
* **Generic Actions Hide Case-Insensitivity**: Normalized `sGenericAction` check for Hide rolls.

### v1.6.1
* Added missing GM awareness summary output when players roll stealth directly from a client.
* Added support for `bTower` flag checking on Dice Tower attack rolls.

### v1.6
* Fixed issue where Stealth effects remained visible to players on Combat Tracker when 'Player: Show Stealth info' option was set to None.
* Explicitly set isgmonly flag on created effect database nodes for GM-only stealth effects and suppressed chat announcements when player stealth info is disabled.

### v1.0.5
* Fixed a `FormattedText SetValue XML Error` that fired on every Perception roll (a raw `<` character in the "did not spot" message broke FGU's chat XML rendering). Chat text is now also escaped defensively against this class of error.
* Fixed attack rolls silently producing no chat output at all. The extension previously replaced the ruleset's own roll handlers and called a captured "original" handler; if that capture ever pointed back at itself (e.g. the extension enabled twice), rolls either crashed with a stack overflow or were swallowed entirely. StealthTracker now only *observes* rolls after the ruleset has fully resolved and displayed them, so it can no longer interfere with roll output.
* Added a hint - "No range to target (are both tokens on the map?)" - when a targeted ranged/thrown attack resolves with no measurable range (both combatants need tokens on an open map for ranged DV to be calculated).
* Fixed critical attack rolls (natural 10) producing two "Target hidden" messages instead of one.
* Fixed Solo characters with Fumble Recovery (rank 4) getting no Stealth processing at all on a recovered fumble.

### v1.0.4
* Fixed "Human Perception" rolls being incorrectly treated as Perception checks (false-triggered active-perception processing).
* Fixed a Lua stack overflow on attack rolls caused by re-initializing on a script/extension reload.

### v1.0.3
* Correctly parse the previous roll's JSON to resolve combined roll details when critical rolls land.

### v1.0.2
* Skip Stealth updates on the initial exploding/fumbling die and wait for the critical roll's final total instead.

### v1.0.1
* Fixed exploding/fumbling dice incorrectly updating the Stealth value shown in the Combat Tracker.

### v1.0
* Initial public release for the Cyberpunk RED ruleset (adapted from the 5E StealthTracker extension).
