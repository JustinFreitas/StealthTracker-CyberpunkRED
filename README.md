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
   * On an actor's turn start in the Combat Tracker, the extension evaluates their **Base Awareness** (`10 + INT + Perception Skill Level`) against all hiding opponents, notifying the GM in chat who they perceive or miss.
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

## Installation & Build

Run the build script in the `/build` folder to package the files into a `.ext` file:
1. Run [build-stealthtracker-zip.bat](file:///C:/code/StealthTracker-CyberpunkRED/build/build-stealthtracker-zip.bat).
2. Move the generated `CyberpunkRED-StealthTracker.ext` file into your Fantasy Grounds Unity `extensions` directory.

---

## Changelog

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
