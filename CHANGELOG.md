# Changelog

## 0.5.5

- Fixed: Power Word: Shield cast on yourself in combat showed only a small
  part of the arc. Your own cast wasn't recognized when the game reported
  your name with the realm, so the shield was treated as someone else's
  with a far too large maximum.
- Missing spell descriptions (they load in the background) are fetched
  again out of combat, so shield sizes are known before the first fight.

## 0.5.4

- Fixed: the Mana Shield arc stayed after the shield broke. A shield that
  breaks in combat is now recognized and its arc disappears.
- Mana Shield shrinks with every hit it absorbs. WoW: Forever hides your mana
  and the damage numbers from addons, so the amount is an estimate (shown with
  `~`): after each fight AbsorbArc reads from the game's damage meter how
  much your Mana Shield really absorbed, and learns per enemy and level how
  much one absorbed hit takes. New enemies use what it learned from enemies
  of a similar level. A Mana Shield that survives a fight shows its exact
  remaining amount afterwards.
- `/aa debug` also writes a log into the saved variables; `/aa total` shows
  the game's total absorb (for testing).

## 0.5.3

- The download now contains only the files the game needs (no README,
  license or screenshots).

## 0.5.2

First release for WoW: Forever.

- Arcs for Ice Barrier, Mana Shield, Fire Ward, Frost Ward, Power Word: Shield,
  Shadow Ward and Sacrifice, with the remaining amount and the seconds left.
- Works in combat: your own shields are recognized when you cast them, the
  amount left comes from the game's total absorb.
- A Power Word: Shield from a priest is recognized, also in combat.
- Mana Shield is counted down from the mana you lose.
- Smooth arcs, also at lowered opacity.
- Settings window (`/aa`), demo (`/aa test`), `/aa status` and `/aa debug`.
