# Lazy

Simple helper for farming XP/CP/Trash items. So far includes:

  - Always Turn to face Target, even if Trust Tank pulls away from you
  - Keep within 3Yalms of Target at all times
  - Weaponskill when TP available
  - Ability to cast a spell whenever Recast/MP allows
  - _SIMPLE_ auto target system

### Installation

* Inside your Windower\Addons folder create a new folder called Lazy
* Copy these files into the folder created above.

### Commands
* //lazy start
* //lazy stop
* //lazy reload
* //lazy save
* //lazy show
* //lazy debug on|off
* //lazy leader
* //lazy follower <player>
* //lazy autotarget on|off
* //lazy target <name>
* //lazy assist <player>
* //lazy buffs on|off
* //lazy cure on|off
* //lazy rest on|off
* //lazy range <yalms>
* //lazy retrust

#### //lazy start
Starts the actual helper

#### //lazy stop
Stops the helper

#### //lazy reload
Reloads the options from the settings.xml

#### //lazy save
Saves the current settings for the current character.

#### //lazy show
Displays the current Lazy status, including main job, assist target,
autotarget state, spell/WS settings, buffs, cure bot, rest, and current
leader/follower mode.

#### //lazy debug on|off
Toggles verbose TargetLogic tracing (default: off). While on, every target
pick, follow decision, and combat-lock state change gets written both to
chat and to `debug/logs/TargetLogic_Debug.txt`, and outgoing attack packets
get traced too. Run with no argument to print whether it's currently on or
off. This is a troubleshooting tool, not something to leave on day to day
— it's noisy.

#### //lazy leader
Switches Lazy into leader mode. Clears the assist target and enables
autotarget. Lazy will select targets itself.

#### //lazy follower "Player Name"
Switches Lazy into follower mode. Sets the specified player as the assist
target and disables autotarget. Lazy follows the assisted player's targets
instead of selecting its own.

Leader and follower are atomic mode switches: each command sets both the
assist and autotarget states together, preventing a stale assist setting or
autotarget state from putting Lazy into an unintended mode.

#### //lazy autotarget on|off
Enables or disables automatic target selection. This is the granular version
of the leader/follower mode controls.

#### //lazy target "Some Monster"
Sets/Changes the current auto target monster, Single mob only for now

#### //lazy assist "Player Name"
Sets/changes who to assist. Independent of autotarget — works whether or not
autotarget is on.

#### //lazy buffs on|off
Toggles RDM auto-buff maintenance (default: on). See `settings.lua` for the
`self_buffs` list (spells kept up on yourself, e.g. Temper, Refresh III,
Gain-STR, an Enspell) and `haste_targets` (party members, besides yourself,
to keep Hasted with Haste II). You're always Hasted automatically; you don't
need to add yourself to `haste_targets`.

Note: we track our own last-cast time per buff against its real duration
(recasting a little early so it never actually drops) rather than reading
buff icons — icon names don't reliably match spell names (enspell tiers,
"Refresh III" vs the "Refresh" icon, etc.), which was causing recasts every
fight even while a buff was still up. This applies to self buffs and to
Haste II on party members alike.

#### //lazy cure on|off
Toggles the WHM cure bot (default: on, only does anything on WHM main job).
Watches the party's HP every half-second; whoever's lowest gets healed with
a cure tier picked off their missing HP (not %) — thresholds and spell
fallback order are ported straight from Ullona's WHM.lua `smartcure`, so
they match what's already proven on GearSwap: under 250 missing tries Cure
then Cure II, under 400 tries Cure II/III/Cure, up through Cure VI past
1400. Each tier tries its spells in order and stops if none are up, rather
than getting stuck retrying one spell that's on cooldown. Also fires Auspice
(or whatever's in that profile's `job_abilities`) the instant it's off cooldown.

#### //lazy rest on|off
Toggles automatic resting (default: on). When enabled, Lazy uses `/heal`
when your MP drops below 500 and you are not currently engaged or under
recent attack pressure. Resting pauses when you are hit, when a self-buff
needs to be maintained, or when a skillchain magic-burst window is pending.
Resting also stops automatically when you become engaged, die, zone, or
disable the feature.

If Lazy is hit while resting and the attacker is a valid, unclaimed target
(or claimed by you), Lazy will target and engage that attacker.

#### //lazy range <yalms>
Sets (or, with no argument, prints) the origin radius — how far from your
anchored origin point (set automatically on `//lazy start`, wherever you
were standing) Lazy is willing to hunt or path to. Mobs outside this
radius are ignored by autotarget/named-target alike.

#### //lazy retrust
Lazy snapshots which party slots are Trusts when you `//lazy start`, and
resummons any of them that die for the rest of the session (player
characters are never touched — only trusts). If you deliberately swap or
release a trust mid-session, run `//lazy retrust` to re-snapshot the
current lineup so Lazy stops trying to bring back one you let go and picks
up whatever you swapped in instead.

### Job profiles
Lazy is main-job aware — it auto-detects your current main job and switches
behavior profiles (`//lazy show` prints which one is active). Profiles live
one-per-file in `Profiles/<JOB>.lua`, loaded automatically by `Lazy.lua`.

All jobs with a file in `Profiles/` are done and ready to use — check that
folder for the current list. Future jobs are to be added the same way, one
file at a time. Any job without a profile yet falls back to `DEFAULT`.

A profile can override `ws_sc_starter`, `ws_sc_closers`, `needed_buffs`, and
`food` — if it doesn't, those fall back to the plain values in
`settings.lua`. So switching your main job in-game actually switches your
whole WS/JA/food kit automatically for any job with a profile; jobs without
one just keep using whatever's in `settings.lua`, same as before job
profiles existed. Edit the relevant `Profiles/<JOB>.lua` file to tweak any
of this, or add a new job's profile the same way.

### settings.xml
```xml
<spell></spell>
<spell_active></spell_active>
<weaponskill></weaponskill>
<weaponskill_active></weaponskill_active>
<autotarget>false</autotarget>
<target>Monster Name<target>
```
* spell - Spell to cast, will cast whenever MP and recast time allows
* spell_active - true/false enables/disables enables casting of the spell
* weaponskill - weaponskill to use when over 1000TP
* weaponskill_active - true/false enables/disables use of weaponskills
* autotarget - true/false enables/disables automatic hunting of mobs in range
* target - name of monster to hunt