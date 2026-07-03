# StealthTracker for Cyberpunk RED (Fantasy Grounds Unity)

StealthTracker is a Fantasy Grounds Unity (FGU) extension designed for the **Cyberpunk RED** ruleset that automates the tracking of Stealth rolls in combat and resolves contested Stealth vs. Perception checks. 

This extension monitors PC and NPC Stealth rolls, records their stealth score as a Combat Tracker effect, and provides real-time notifications to the GM comparing current actor stealth to observer awareness. It also intercepts active Perception rolls and compares them directly against hiding combatants.

---

## Key Features

1. **Automated Stealth Tracking**:
   * When an actor rolls a **Stealth** check, the total result is automatically tracked as a Combat Tracker (CT) effect: `Stealth: [Total]`.
2. **Active Perception vs. Tracked Stealth**:
   * When a player or NPC rolls an active **Perception** check, the extension automatically compares the roll against all hiding enemies in the Combat Tracker and reports exactly who is spotted (e.g. `GUARD A SPOTTED Player B! (Perception roll 14 >= Stealth 12)`).
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
2. Move the generated `StealthTracker.ext` file into your Fantasy Grounds Unity `extensions` directory.
