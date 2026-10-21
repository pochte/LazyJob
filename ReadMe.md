# Lazy

Helper for farming XP/CP/trash items while you're away from the keyboard.
So far it:

  - Hunts mobs around a starting spot, fights them, and always turns to face
    the target, even if a Trust tank pulls away from you
  - Keeps within range of the target, and weaponskills when TP is available,
    including ordered skillchains of up to 5 weaponskills
  - Can cast a spell whenever recast/MP allows
  - BLM and SCH magic burst, and can free nuke between bursts with the right
    element for the mob, plus a weather failsafe
  - Is main-job aware: each job has a profile (buffs, debuffs, party buffs,
    cures, magic bursts, abilities, food)
  - Cure bot, and resting for mage jobs
  - Tracks your Trusts and resummons any that die
  - Lets someone join a running party: they send a tell, Lazy pauses,
    invites them, level syncs and rebalances the Trusts
  - Takes party-chat commands (reset, go home, stop, start, hold, resume,
    regroup, rebuff, tnl) from everyone running Lazy, or only from names you
    trust
  - Raises dead party members (WHM first, then SCH, RDM, PLD and sub-job
    raisers), deals with Doom, and cleanses debuffs with WHM/SCH

### Installation

* Inside your Windower\Addons folder create a new folder called Lazy
* Copy these files into the folder created above, keeping the folders as
  they are:

```
Lazy.lua            the engine: commands, settings, combat loop, buffs, cures
settings.lua        shared configuration (lists, party join, targeting rules)
skills.lua          weaponskill / skillchain data
profiles/           one profile per job (RDM.lua, WHM.lua, ...)
Logic/
  TargetLogic.lua   ALL targeting: choosing, combat lock, pathing, follow,
                    damage tracking, aggro queue, Combat, TurnToTarget
  TrustLogic.lua    trust tracking and resummon, party member jobs/levels,
                    level sync
  PartyCommands.lua party join ("chicken nuggets"), party-chat commands,
                    rez, Doom and debuff cleansing, session stats, go home
  JobLogic.lua      cast helpers, weaponskill getters and modes
  HealBuffLogic.lua cure bot, buffs, debuffs, dispel (mage jobs only)
  RestLogic.lua     resting (mage jobs only)
  dnc_logic.lua     Dancer rotation (loaded on DNC)
  rolls.lua         Corsair rolls (loaded on COR)
  skillchain.lua    skillchain window and step tracking
  magicburst.lua    magic bursts, BLM/SCH free nuke and weather failsafe
debug/Debug.lua     debug logging and the /attack safety gate
data/settings.xml   per-character settings, written by //lazy save
                    (private: listed in .gitignore, keep it out of the repo)
```

### Commands
* //lazy start
* //lazy stop
* //lazy reload
* //lazy save
* //lazy show
* //lazy debug on|off
* //lazy leader
* //lazy follower \<name\>
* //lazy autotarget on|off
* //lazy target "Some Monster"
* //lazy fight
* //lazy range \<yalms\>
* //lazy buffs on|off
* //lazy cure on|off
* //lazy rest on|off
* //lazy burstmode
* //lazy freenuke
* //lazy nukeoff
* //lazy chainmode
* //lazy openmode
* //lazy partychain
* //lazy retrust
* //lazy join \<name\>
* //lazy join cancel
* //lazy sync \<name\>
* //lazy sync off
* //lazy trust add|remove \<name\>
* //lazy trust list|clear
* //lazy tnl
* //lazy party \<phrase\>

#### //lazy start
Starts the helper. It records where you are standing as the origin (hunting
stays within `//lazy range` yalms of it), detects your main job and loads its
profile, snapshots your Trusts, and starts everything. It also clears any
leftover target and combat state from an earlier run. If you haven't picked a
mode (no `//lazy follower <player>` target and autotarget is off) it defaults
to leader mode, i.e. autotarget on. Running it again while Lazy is already
running does nothing. It prints the weaponskill mode and nuke mode in use, so
the defaults are visible (see [Defaults](#defaults)). It refuses to start
while you are dead. If you die while it is running and nobody else is alive
in the party, Lazy tells you what killed you and stops. If other players are
alive, the character asks the party for a rez instead and waits (see
[Rez](#rez)); Lazy only stops if no raise arrives within `rez_timeout`
seconds.

#### //lazy stop
Stops the helper. Your settings are kept.

#### //lazy reload
Fully reloads the addon: every file, including profiles and `settings.lua`.
Your current settings are saved to `data/settings.xml` first. If Lazy was
running, it restarts itself a few seconds after the reload; if it was stopped,
it stays stopped.

#### //lazy save
Saves the current settings (the ones in [settings.xml](#datasettingsxml-per-character))
for the character you are logged in as.

#### //lazy show
Prints the current state: main job, autotarget, spell, weaponskill, the
weaponskill mode (chain or open), the nuke mode on BLM/SCH, target, and whether buffs, the cure bot and
resting are on.

#### //lazy debug on|off
Turns debug logging on or off; with no argument it says which it is. When on,
Lazy prints target changes, `/attack` traces and party-permission packets
(`0x077`, used by level sync) to chat and also writes them to
`TargetLogic_Debug.txt` in the addon folder. The `/attack` safety gate (it
blocks `/attack on` without a combat lock, on the wrong target, or while
already engaged) is always active, debug on or off.

#### //lazy leader
Leader mode: autotarget on and assist cleared. Lazy picks the fights.

#### //lazy follower \<name\>
Follower mode: assist that player and turn autotarget off. Lazy fights what
they fight. If the profile has `auto_engage = false` (mages) it stays
disengaged.

#### //lazy autotarget on|off
Turns automatic hunting on or off. While on, Lazy fights the nearest mob that
is on your `targeting.monsters` list (in `settings.lua`), alive, unclaimed,
and within `//lazy range` of the origin (the `targeting` rules there can
relax those). If there is none and you are not
soloing, it joins a mob a party member has claimed. With nothing to fight it
walks back to the origin. An assist target (below) wins over autotarget while
one is set.

#### //lazy target "Some Monster"
Hunts only mobs with that name instead of the `targeting.monsters` list.
Single mob name only for now. `//lazy target` with no name clears it.

#### //lazy fight
Target the mob you want, then run this: it fills in `//lazy target` with that
mob's name for you. It refuses if you have no target, you are the target, or
the target is a party member or Trust.


#### //lazy range \<yalms\>
Sets how far from the origin Lazy will hunt (default 10). With no number it
prints the current radius.

#### //lazy buffs on|off
Turns buff maintenance on or off (default: on). What gets kept up depends on
the job profile: `self_buffs`, `needed_buffs`, `party_buffs`, `debuffs`,
`self_abilities`, `entrust_buffs` and so on (see [Job profiles](#job-profiles)).

We track our own last-cast time per buff against its real duration
(recasting a little early so it never actually drops) rather than reading
buff icons. Icon names don't reliably match spell names (enspell tiers,
"Refresh III" vs the "Refresh" icon, etc.), which was causing recasts every
fight even while a buff was still up. This applies to self buffs and to
party buffs alike.

#### //lazy cure on|off
Turns the cure bot on or off (default: on). It watches the party's HP every
half-second and heals whoever is lowest once they are under 75%, picking a
cure tier from their missing HP (not %) using the profile's `cure_tiers`.
Each tier tries its spells in order and stops if none are up, rather than
getting stuck retrying one spell that's on cooldown. Who cures is up to the
profile:

* WHM: always (`cure_bot_active`)
* SCH: only when there is no WHM in the party (`cure_bot_if_no_whm`)
* RDM and anything with `emergency_cure`: only as a failsafe, when someone
  drops below `emergency_cure_threshold` (default 25%)

#### //lazy rest on|off
Turns resting on or off (default: on). Mage jobs (WHM, RDM, BLM, GEO, SCH,
SMN; an RDM with NIN sub does not rest) use `/heal` when idle and MP is below 500, and stand up
when anything needs them: you are being hit, a party member within 30 yalms
is under 60%, or a magic burst window is open. If something attacks you
while you are idle, Lazy engages it.

**#### //lazy burstmode**  
Jobs with Elemental Magic: automatically nuke only during magic bursts, when a skillchain window is open. This is the default mode. See [Free nuke](#free-nuke-blm-and-sch).

**#### //lazy freenuke**  
Jobs with Elemental Magic: automatically nuke between bursts using tier IV and lower spells in the element the target is weak to, while reserving tier V and VI spells for magic bursts. Jobs without applicable Elemental Magic nuking support will receive a message and remain unchanged. This mode lasts for the session. See [Free nuke](#free-nuke-blm-and-sch).

**#### //lazy nukeoff**  
Disables automatic Elemental Magic nuking, including free nukes and magic bursts. Use `//lazy burstmode` or `//lazy freenuke` to re-enable automatic nuking. This mode lasts for the session.

#### //lazy chainmode
Switches weaponskills to the full ordered skillchain, `ws_sc_chain` (up to 5
steps, see [Skillchains](#skillchains)). If the current profile has no
`ws_sc_chain` it says so and stays in open mode.

#### //lazy openmode
Switches weaponskills back to opener + closers only: `ws_sc_starter` opens,
and a closer from `ws_sc_closers` fires when one continues the open
skillchain. A profile that only defines a chain (no starter/closers of its
own) uses the chain's first two entries as the opener and closer.

The mode lasts for the session and starts in chain mode, so a profile with a
`ws_sc_chain` uses it until you run `//lazy openmode`.

#### //lazy partychain
Weaponskill mode for chaining with a party. Lazy opens with the profile's
`ws_sc_starter`, then continues whatever skillchain is open, whoever started
it, with the best weaponskill it can use right now (see
[Skillchains](#skillchains)). When nothing continues it, Lazy does nothing and
the burst takes the end of the chain.

#### //lazy retrust
Lazy snapshots which party slots are Trusts when you `//lazy start`, and
resummons any of them that die for the rest of the session (player
characters are never touched, only Trusts). If you deliberately swap or
release a trust mid-session, run `//lazy retrust` to re-snapshot the
current lineup so Lazy stops trying to bring back one you let go and picks
up whatever you swapped in instead.

#### //lazy join \<name\>
Runs the party-join flow for that player, exactly as if they had sent the
tell phrase (see [Party join](#party-join)). Lazy must be started.

#### //lazy join cancel
Cancels a party join in progress and resumes normal botting.

#### //lazy sync \<name\>
Level syncs the party to that party member. Only the party leader's request
is accepted by the game, so this only works while you are leader. Useful for
testing the packet on its own. Level sync strips buffs and dismisses trusts,
same as doing it from the party menu.

#### //lazy sync off
Turns level sync off (the cap lifts after about 30 seconds).

#### //lazy trust add|remove \<name\>, //lazy trust list|clear
Manages who may use the [party commands](#party-commands). With an empty list
(the default) everyone in the party can. Once there is a name on it, only
listed players can. The list is saved straight away to the
`<trusted_players>` entry of your character in `data/settings.xml`. `list`
shows it, `clear` empties it (everyone allowed again). The "chicken nuggets"
tell has its own `allowed_senders` list in `settings.lua`.

#### //lazy tnl
Prints this session's stats to the console: how long Lazy has run, kills,
EXP and EXP per hour, limit points, and EXP to the next level with a rough
time to get there. Counting starts at `//lazy start`. A kill is counted when
you get EXP or limit points for it, so mobs that give nothing aren't counted.
The same thing is printed after `go home`.

#### //lazy party \<phrase\>
Runs a [party command](#party-commands) on this character only, as if a
trusted player had said it: `//lazy party reset`, `//lazy party go home`, and
so on. Handy for testing.

### Defaults
Nothing needs setting before `//lazy start`; these are what you get:

* **Targeting:** leader mode (autotarget on) when no assist is set.
* **Weaponskills:** chain mode. A profile with a `ws_sc_chain` fires it; a
  profile without one uses normal weaponskills (its `ws_sc_starter` and
  `ws_sc_closers`). `//lazy openmode` forces the normal ones.
* **Nuking (BLM and SCH):** burst only. Free nuke stays off until you run
  `//lazy freenuke`.
* **Magic burst:** only at the end of a chain, see
  [Magic burst timing](#magic-burst-timing).

Lazy prints the weaponskill and nuke modes when it starts.

### Party join
For when a bot disconnects, or a player wants to join later: the person logs
in, sends the bot a tell containing the phrase (default `chicken nuggets`,
not case sensitive), and Lazy brings them into the party. Lazy must be
started (`//lazy start`) for the tell to do anything.

1. New pulls pause. A fight already in progress is allowed to finish (up to
   `fight_timeout` seconds). Lazy only waits while you are fighting a live
   monster: if you are engaged on nothing it disengages and carries on, and
   it prints a line every 20 seconds while it is really waiting.
2. If the party is full and Trusts are in it, Lazy dismisses them first
   (`/retr all`) and waits for the slots to free up, because a full party
   can't accept the invite. Then it invites them (`/pcmd add`) and waits up
   to `invite_timeout` seconds for them to accept, re-sending the invite once
   halfway. If they never accept, Lazy tells them so and goes back to
   botting.
3. Once they're in, Lazy reads their job and master level and level syncs the
   party to the lowest master level. **Only characters with master level 1 or
   higher count**: a non-master is ignored, because syncing to one would make
   everyone too weak to fight. No sync is sent if everyone counted is the
   same master level, if a sync is already active, or if Lazy doesn't know a
   master level yet. Trusts that are still out are dismissed before the sync
   is requested. If the sync doesn't take within a few seconds, Lazy
   says so and waits up to 45 seconds for you to do it from the party menu.
4. The party has six slots and the new player took one, so Lazy works out how
   many trusts to leave out. A trust whose job matches the new player's goes
   first (a RDM joins: Koru-Moru stays out; a WHM joins: Yoran-Oran stays
   out). If none match, trusts are dropped in `trust_sacrifice_order`.
   The rest are resummoned.
5. The new player is told they're in, and normal botting resumes.

Settings (all in `settings.lua`):
```lua
party_join = {
    enabled = true,
    phrase = 'chicken nuggets',
    allowed_senders = {},      -- {} = anyone who knows the phrase; or { 'Name1', 'Name2' }
    invite_timeout = 60,       -- seconds to wait for them to accept
    fight_timeout = 120,       -- seconds to let a fight in progress finish first
    level_sync = true,
}
trust_jobs = { ['Ulmia'] = 'BRD', ['Koru-Moru'] = 'RDM', ... }   -- trusts by party name
trust_sacrifice_order = { { 'Ulmia', 'Joachim' }, { 'Qultada' } }
```
By default anyone who knows the phrase can use it, so put names in
`allowed_senders` if you don't want that. Trust names are the ones shown in
the party list (`Yoran-Oran`, not `Yoran-Oran (UC)`); the game has no job
data for trusts, so `trust_jobs` is hardcoded.

### Party commands
Everyone running Lazy listens to party chat. Say one of these as the **whole
line** (case doesn't matter) and every character running Lazy reacts for
itself. Rename any of them under `party_commands.phrases` in `settings.lua`.
Lazy has to be started on a character for it to react (except `start`).

| Say | What happens |
| --- | --- |
| `reset` | Everyone re-anchors the origin where they stand and forgets which mobs it had given up on. For when someone got stuck behind a rock |
| `go home` | Everyone warps out, then Lazy stops and prints the session stats (see below) |
| `stop` / `start` | Stops or starts Lazy on everyone |
| `hold` | No new pulls, fights in progress finish |
| `resume` | Carries on after `hold` or `regroup`, with a new origin where each character is standing (the "camp here" command) |
| `regroup` | Everyone runs to the party leader and holds. Say `resume` to carry on |
| `rebuff` | Forgets every buff timer so all buffs are recast |
| `tnl` | Each character prints its own session stats to its console (same as `//lazy tnl`) |

#### How to use them in game
1. Start Lazy on every character that should react (`//lazy start`). A
   character that isn't running Lazy ignores all of this. `start` is the one
   exception: it can start a stopped Lazy.
2. Type the phrase in **party chat**, as the whole line and nothing else:
   ```
   /p reset
   /p go home
   /p hold
   ```
   (`/p` and `/party` both work.) Every character in the party that is running
   Lazy reacts, including the one you typed it on. Each one prints a
   `[Lazy] ...` line in chat so you can see it heard you.
3. Typical flow after a mess: `/p hold` (stop pulling), `/p regroup` (everyone
   runs to the leader), then `/p resume` (everyone carries on from where they
   stand, new origin).
4. To try a command on just one character, run `//lazy party <phrase>` in
   that character's console, for example `//lazy party reset` or
   `//lazy party go home`. It behaves as if a trusted player said it.

Only **party chat** counts. Tells, say, shout and linkshell chat are ignored,
and so is a line with anything extra in it (`/p please reset` does nothing).
`rez`, Doom and debuff cleansing need no typing: they happen by themselves
while Lazy is running (cleansing also needs `//lazy cure` on).

If nothing happens:
* Lazy isn't started on that character (`//lazy start`).
* The sender isn't on your trusted list. You'll see
  `Ignored "..." from <name> (not on the trusted list)`. Check
  `//lazy trust list`, or `//lazy trust clear` to allow everyone.
* It wasn't party chat, or the line had extra words in it.
* You renamed the phrase in `settings.lua`; use the new one.

**Who can use them.** By default everyone in the party. Add names with
`//lazy trust add <name>` and only those players are listened to; anyone else
gets one line in chat saying they were ignored. The list lives in
`data/settings.xml` (`<trusted_players>`, comma separated), which is private
to you: it is listed in `.gitignore` so character names stay out of the repo.
If it was already committed once, run `git rm --cached data/settings.xml`.

**go home.** Each character tries these in order, using the first it has:
Warp Ring, Treat Staff, Warp Cudgel, Instant Warp. An item in a satchel,
sack or case is moved to the inventory first; rings and staves are equipped
(ring2 / main) and Lazy waits out the equip delay before using them. If
nothing works it prints `go home command executed, no way home. Character has
been logged out.` to the console and logs out. When the zone changes Lazy
stops itself and prints the stats. A dead character skips it. The list of
items is `party_commands.go_home_items`.

#### Rez
A character at 0 HP says `rez` in party chat and waits (the party pauses its
pulls). Someone else raises them, in this order: WHM, SCH, RDM, PLD, then any
other job whose sub job can raise (a GEO /WHM, for example). Each waits its
turn (`rez_step` seconds apart, longer for the sub-job raisers) so only one
casts, and says `rezzing` so the rest stand down. It casts the best raise it
can at the level it has (Arise, Raise III, Raise II, Raise), walking into
range first. The raised character accepts the raise prompt by itself, then
the whole party waits until Weakness has worn off before botting again
(`wait_for_weakness`, never longer than `rez_pause_max`). Trusts that died
with the leader are resummoned by the normal Trust recovery. If nobody
raises within `rez_timeout` seconds, Lazy stops on the dead character as it
used to. GEO can't raise from its main job, which is why it comes last.

#### Doom
A doomed character says so in party chat **once**, uses Holy Water (if it has
some in the inventory) every few seconds, and anyone who can cast Cursna
(WHM or SCH, main or sub) casts it on them until the Doom is gone. If they
die anyway, the rez above takes over.

#### Debuff cleansing
Characters that can cast the right spell (WHM and SCH, main or sub job) clear
debuffs on party members within 20 yalms with no chat involved: Poisona,
Paralyna, Blindna, Silena, Stona, Viruna (disease and plague), Cursna (curse
and Doom) and Erase for Slow, Weight, Bind, Addle and the stat-down effects.
Everyone waits a short turn first so two healers don't both cast. Add names
to `party_commands.cleanse_ignore` to leave a debuff alone; **Evasion Down is
ignored by default** because it is applied constantly. Needs `//lazy cure` on.

Settings (all optional, in `settings.lua`):
```lua
party_commands = {
    -- phrases = { go_home = 'go home' },   -- rename any phrase
    rez_enabled = true,
    rez_timeout = 180,         -- dead this long with no raise: Lazy stops
    rez_step = 4,              -- seconds between each raiser's turn
    rez_last_ditch_wait = 10,  -- extra wait for sub-job-only raisers
    rez_give_up = 90,          -- stop working on one corpse after this long
    rez_pause_max = 900,       -- never keep the party paused longer than this
    wait_for_weakness = true,
    raise_accept_param = 0,    -- try 1 if the dead character declines the raise
    doom_holy_water = true,
    holy_water_tries = 8,
    cleanse_step = 2,
    cleanse_ignore = { 'Evasion Down' },
    regroup_timeout = 45,
    go_home_items = {
        { name = 'Warp Ring',   slot = 'ring2' },
        { name = 'Treat Staff', slot = 'main' },
        { name = 'Warp Cudgel', slot = 'main' },
        { name = 'Instant Warp' },
    },
}
```
New party-chat phrases and `//lazy` commands live in `Logic/PartyCommands.lua`
(`PHRASE_HANDLERS` and `Party_Command`).

### Magic burst timing
Every job with magic burst (BLM, SCH, GEO, RDM, WHM, and NIN when its profile
has `magic_burst`) bursts at the **end of a chain**, not in the middle of
one. A burst cast mid-chain eats the window the next weaponskill needs and
gives up the bigger bonus a longer chain earns.

* **Closed chain** (level 4, Radiance or Umbra, or past the last step):
  nobody can continue it, so it is burst right away.
* **Open chain** (Light, Darkness, Fusion, anything that can still be
  continued): burst once nobody has continued it for `burst_quiet` seconds
  (default 2). If someone does continue it in that time, Lazy waits for the
  next window.
* A job's own chain keeps the window while it still has something to fire: an
  ordered chain with an affordable next step, or partychain with a weaponskill
  that continues the skillchain.
* `burst_when = 'any'` bursts any open window as soon as it opens.

**Which element.** Lazy follows bg-wiki's Elemental Alignments. For a given
skillchain it tries, in order: the mob's weakness (from `nuke_weakness`) if
that element can burst this skillchain, then the default order.

| Skillchain | Elements that burst it (default order) |
| --- | --- |
| Light, Radiance | Wind, Lightning, Fire, Light |
| Darkness, Umbra | Dark, Ice, Water, Earth |
| Fusion | Fire, Light |
| Fragmentation | Wind, Lightning |
| Gravitation | Earth, Dark |
| Distortion | Ice, Water |
| Transfixion / Compression / Liquefaction / Scission / Reverberation / Detonation / Induration / Impaction | Light / Dark / Fire / Earth / Water / Wind / Ice / Lightning |

Dark is Comet on BLM and Impact on RDM, SCH and GEO; Light is Holy II then
Holy on WHM; all set by each profile's `burst_spells`. Change the order for a
skillchain with `burst_elements` in `settings.lua`.

**Burst as often as the window allows.** While a window is open Lazy checks
four times a second and casts again as soon as the last cast has finished
(`burst_gap`, 0.7 seconds apart), so fast cast can burst two or three times in
one window. It won't start a cast with less than `burst_min_left` seconds of
window left.

In `settings.lua`:
```lua
burst_when = 'final'   -- default: the end of a chain; 'any' = any open window
burst_quiet = 2        -- seconds an open chain must sit untouched to have ended
burst_min_left = 0.8
burst_gap = 0.7
-- burst_elements = { Light = { 'Wind', 'Fire' } }
```
Things to know:
* A job only bursts an element it has spells for: the stock BLM, SCH, GEO, RDM
  and WHM profiles cover everything above except that WHM only has Light.
* A melee job that bursts (NIN) does not open a new chain on top of a window
  it is about to burst.
* Casting is not blocked by action delay while a window is open, but a cast
  never overlaps another.

### Free nuke (BLM and SCH)
BLM and SCH have two nuke modes, switched with `//lazy burstmode` and
`//lazy freenuke`:

* **Burst mode** (default): nuke only when a window can be burst (the end of
  a chain, see [Magic burst timing](#magic-burst-timing)), using the
  profile's `burst_spells`, highest tier first.
* **Free nuke**: bursts work the same, and in between Lazy nukes the target
  with tier IV and lower (`free_nuke_max_tier`, default 4), trying IV, then
  III, II and I as recasts allow. Tier V and VI are never used for free nukes.

GEO and RDM are too busy (curing, meleeing) and NIN has its own spells, so
this is only on for profiles with `free_nuke = true` (BLM and SCH).

**Which element.** Most mobs have an elemental weakness, so the spell depends
on the mob. `nuke_weakness` in `settings.lua` is an ordered list; the mob's
name is matched as whole words, case-insensitive, first match wins:
```lua
nuke_weakness = {
    { 'Worm',   'Fire' },
    { 'Bat',    'Aero' },
    { 'Beetle', 'Blizzard' },
    { 'Eft',    'Blizzard' },
    { 'Crab',   'Blizzard' },
}
-- nuke_default = 'Thunder'   -- element for mobs that match nothing
```
The element is the spell family: Fire, Blizzard, Aero, Stone, Thunder or
Water. A mob that matches nothing is not free nuked (Lazy prints a note once
per mob name) unless `nuke_default` is set. A profile can set its own
`nuke_weakness`.

**Weather failsafe.** Before a free nuke, if neither the weather nor a storm
of yours matches the nuke's element, Lazy casts the matching Storm on you
(Storm II if you can, otherwise Storm I). This is only a backup for when
GearSwap hasn't already done it. Only SCH can cast storms: SCH main, or SCH
sub at a high enough level (Storm I needs sub level 41 to 48 depending on
the storm; Storm II is level 100). It is skipped silently when it can't be
cast, and turned off with `free_nuke_weather = false` in the profile. It
only runs before free nukes, never before a burst, since a burst can't
wait for a cast.

Other rules:
* A free nuke is held back while a skillchain window is open, so the window is
  left for the burst.
* It keeps enough MP back to still cast the family's top burst spell.
* The target must be a live monster within 19 yalms that is unclaimed or
  claimed by you or your party, not on `spell_blacklist`, and Lazy won't
  start a new pull while a Trust recovery or party join is pausing pulls.
* Nothing is cast while you are moving or casting.

Magic burst itself had a gap that is now fixed: skillchain elements are named
Ice, Wind, Earth and Lightning, but the profiles' burst lists are keyed by
spell family, so those four skillchains never got a burst before. They now map
to Blizzard, Aero, Stone and Thunder.

### Skillchains
Two ways to define what Lazy fires, switched with `//lazy chainmode` and
`//lazy openmode`.

**Chain** (`ws_sc_chain`): up to 5 weaponskills fired in exactly this order.
Entry 1 opens the chain; after each step lands, the next entry fires, and
after the last entry Lazy waits for the window to end before opening again.
An entry is a name, or `{ name, min_tp }` (default 1000):
```lua
ws_sc_chain = {
    { 'Savage Blade', 2000 },
    'Aeolian Edge',
    'Evisceration',
    "Rudra's Storm",
    'Exenterator',
}
```
For just a short chain, list fewer entries. Steps are counted per target no
matter who landed them, so a step a party member adds moves the chain along.
While a chain window is open, Lazy does not fire the opener on top of it.

**Open** (`ws_sc_starter` / `ws_sc_closers`): the original opener + closers.
The closer is whichever one in `ws_sc_closers` continues the skillchain that
is currently open.

Both can live in a job profile (`profiles/<JOB>.lua`) or as defaults in
`settings.lua`. A profile's own values win, and a profile can define a chain
and starter/closers together so both modes do something different.

**Partychain** (`//lazy partychain`): the opener is the profile's
`ws_sc_starter` (or the first entry of its chain). After that, whenever a
skillchain is open, Lazy looks at the weaponskills the character can use right
now, works out which skillchain each one would make from the open chain's
properties, and fires the one that makes the **highest level**. Ties go to the
order of `partychain_prefer` (a list of weaponskill names, in a profile or
`settings.lua`), then alphabetically. It looks one step ahead only: it does
not plan a route to Radiance, and it does not know what other players will use
next. If nothing continues the chain it does nothing, and the burst takes the
end. Steps count whoever landed them, and it needs 1000 TP like any other
step.

### Job profiles
Lazy is main-job aware: it detects your current main job and switches
behavior profiles (`//lazy show` prints which one is active). Each profile is
its own file, `profiles/<JOB>.lua`, which fills in `JOB_PROFILES.<JOB>`.
Unlisted jobs fall back to `DEFAULT`, which does nothing (no melee, no
weaponskills).

Profiles are loaded from the list near the top of `Lazy.lua`
(`profile_list`: RDM, GEO, BLM, SCH, DNC, NIN, WHM, WAR, THF, COR, BRD,
DEFAULT). To add a job, create `profiles/<JOB>.lua` and add the job to that
list.

Currently defined:

| Job | What its profile does |
| --- | --- |
| RDM | Melee. Self buffs (Haste II, Temper II, Gain-STR, Enfire II), debuffs (engage first, then debuffs, then everything else, and it holds a skillchain until they are cast), party Haste II and Refresh III, Composure/Saboteur, Dispel, magic burst, emergency cures |
| WHM | Cure bot, Protectra/Shellra/Auspice and other self buffs, bursts Light with Holy II and Holy. No melee |
| BLM | Magic burst (Tier VI cap) and free nuke (`//lazy freenuke`, tier IV and lower). No melee |
| SCH | Magic burst and free nuke (`//lazy freenuke`), plus the cure bot when there is no WHM in the party |
| GEO | Indi-Fury, Luopan abilities (Radial Arcana, Dematerialize, Life Cycle), Entrust (Indi-Refresh on a mage; Indi-Haste on the party leader when they are the only other player and their job can't be read; otherwise Indi-Frailty), Geo-Frailty, magic burst |
| BRD | Party songs (Honor March, Knight's Minne V). No melee |
| COR | Rolls (`rolls.lua`), Wildfire opener |
| DNC | Dancer rotation (`dnc_logic.lua`), Rudra's Storm |
| NIN | Kakka: Ichi, magic burst with Raiton/Hyoton. Weaponskills: open mode is Blade: Ten opener and closer, chain mode (`//lazy chainmode`) is Blade: Shun > Blade: Kamu > Blade: Shun, repeating |
| THF | Conspirator, Sneak Attack, Trick Attack, Rudra's Storm |
| WAR | Upheaval opener, Ukko's Fury closer, Hasso/Berserk/Blood Rage/Aggressor, re-provoke if stuck |

Mage jobs (WHM, RDM, BLM, GEO, SCH, SMN) load `HealBuffLogic.lua` and
`RestLogic.lua`, which replace the simpler buff/cure code in `Lazy.lua`;
other jobs use the simpler code. DNC and COR load `dnc_logic.lua` and
`rolls.lua`.

Other players' jobs come from the game's party packets, which are sent when
someone joins, zones or changes job, so a member who was already in the party
when Lazy loaded can show as `job?` until then. The Entrust debug line
(`[Lazy][Entrust]`, on by default; `ENTRUST_DEBUG` in `HealBuffLogic.lua`)
prints every party slot with the job Lazy sees, who the leader is, and why
Entrust can't be used yet (for example `on recast, 312s left`).

Keys a profile can set (anything else in a profile is ignored):

| Key | Meaning |
| --- | --- |
| `auto_engage` | `false` = never attack (mages); stay out of melee |
| `use_weaponskills` | weaponskill when TP allows |
| `engage_distance`, `ranged_pull` | how close to get; ranged pull settings (`range`, `engage_distance`) |
| `ws_sc_starter`, `ws_sc_closers`, `ws_sc_chain` | weaponskills, see [Skillchains](#skillchains) |
| `needed_buffs`, `food` | buffs/abilities kept up by name, and food to eat |
| `self_buffs` | spells kept up on yourself: `{ name, interval (minutes), fallback }` |
| `self_abilities` | job abilities with conditions (`require_pet`, `max_mp_percent`, `min_pet_hpp`, `max_pet_hpp`) |
| `party_buffs` | `{ spell, targets ('ALL_PLAYERS' or { jobs = {...} }), interval, range, self }` |
| `entrust_buffs` | Entrust + Indi spell on a chosen party member (GEO). `targets` is `{ jobs = {...} }`, `{ players_only = true }`, or `{ lone_leader_unknown_job = true }` (the only other player, job unreadable, holding party leader). Set `fallback = true` to use an entry only when no earlier entry has a target |
| `debuffs`, `dispel` | debuffs on the target, and Dispel (only on `dispel_whitelist` mobs) |
| `debuffs_engaged_only` | `true` = cast the debuffs only once engaged, not while the pull is still pending (RDM) |
| `debuff_hold_hpp` | RDM: while a debuff is due and castable, weaponskills and nukes wait for it (at most 8 seconds). Above this mob HP% every debuff holds them; at or below it only the first one in the list does (default 50) |
| `haste_active`, `haste_samba_active`, `haste_targets` | haste handling |
| `magic_burst`, `burst_spells`, `magic_burst_requires_buff` | burst during skillchain windows: spell family (Fire, Blizzard, Aero, Stone, Thunder, Water, Darkness, Light) mapped to spells, best first |
| `free_nuke`, `free_nuke_max_tier`, `free_nuke_weather` | BLM/SCH free nuke: on/off, highest tier cast outside bursts (default 4), storm failsafe (default on) |
| `nuke_weakness`, `nuke_default` | mob name to element for free nukes, see [Free nuke](#free-nuke-blm-and-sch) |
| `cure_bot_active`, `cure_bot_if_no_whm`, `cure_bot_requires_buff` | when the cure bot runs |
| `cure_tiers` | `{ max_missing, spells }` list picked by the target's missing HP |
| `emergency_cure`, `emergency_cure_threshold` | failsafe curing for non-healers |
| `provoke_if_stuck`, `stuck_threshold` | provoke and re-face if engaged without landing hits |
| `dnc_rotation`, `job_abilities` | job-specific hooks |

Anything a profile leaves out falls back to the plain values in
`settings.lua`, so a job without a profile just keeps using what is there.

### Settings

#### settings.lua
Shared configuration, edited by hand and reloaded with `//lazy reload`:
weaponskill fallbacks (`ws_sc_starter`, `ws_sc_closers`, optional
`ws_sc_chain`), `spell_blacklist` (mobs never to cast the configured spell
on), `dispel_whitelist` (mobs Lazy may Dispel/Finale), `haste_blacklist`
(players who never get Haste II), `burst_when`, `burst_quiet`, `burst_min_left`, `burst_gap`, `burst_elements` (magic burst),
`partychain_prefer` (partychain tie-breaks),
`nuke_weakness` / `nuke_default` (free nuke),
`party_join`, `trust_jobs` and
`trust_sacrifice_order` (see [Party join](#party-join)), `party_commands`
(see [Party commands](#party-commands)), `targeting`
(`monsters` list, `only_unclaimed`, `only_alive`, `within_origin`),
`needed_buffs`, `food`, and `subjob_abilities` (for example Haste Samba for
any job subbing DNC).

#### data/settings.xml (per character)
Written by `//lazy save`, read when the addon loads. Keys under `<global>`
apply to every character, and a section named for a character overrides them
for that character.
```xml
<spell></spell>
<spell_active></spell_active>
<weaponskill></weaponskill>
<weaponskill_active></weaponskill_active>
<autotarget>false</autotarget>
<target>Monster Name</target>
<assist></assist>
<buffs_active>true</buffs_active>
<cure_active>true</cure_active>
<rest_active>true</rest_active>
<trusted_players></trusted_players>
```
* spell - Spell to cast, will cast whenever MP and recast time allows
* spell_active - true/false enables/disables casting of the spell
* weaponskill, weaponskill_active - legacy; weaponskills now come from the job
  profile / `settings.lua`, and these are only shown by `//lazy show`
* autotarget - true/false enables/disables automatic hunting of mobs in range
* target - name of monster to hunt
* assist - player to assist, empty for none
* buffs_active, cure_active, rest_active - what `//lazy buffs`, `//lazy cure`
  and `//lazy rest` toggle
* trusted_players - comma separated names allowed to use the party-chat
  commands, empty = everyone. Managed with `//lazy trust`