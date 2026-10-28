---
name: game-design-doc
description: Turn a game idea into a scoped, buildable GDD.md — pitch, core loop, mechanics, controls, fail and win states, progression, art direction, audio, asset list and a cut list — by interviewing the user in rounds until every design decision is settled. Use when the user says "I want to make a game", "design a game", "game idea", "write a GDD", "game design document", "help me scope my game", "plan a game jam entry", or starts a game project without a written design.
metadata:
  author: Jibaru
  version: 1.0.0
---

# game-design-doc

Produce `GDD.md` at the root of the game project, which is the file every
other `game-*` skill reads. Don't write the file until the interview is done.
A GDD written from a one-line prompt is fiction, and the code built on it
gets thrown away.

## The interview

Map the design as a **tree**: every decision has decisions that hang off it
("it's a platformer" → "does the player double jump?" → "can enemies be
stomped?"). Work the tree in **rounds**.

The **frontier** is every open decision whose prerequisites are already
settled. Each round, ask the whole frontier at once. Number the questions,
and give your recommended answer for each so the user can answer "ok":

```
❓ **Q1 - <title>**: <question, with concrete options where it helps>

➡️ <your recommendation, and why in one line>

---

❓ **Q2 - …
```

A question that depends on another question still open in the same round
waits for a later round. Recompute the frontier after every set of answers.
Match the user's language: if they write in Spanish, interview in Spanish,
and write the GDD in Spanish.

**Facts are your job, decisions are theirs.** Don't ask the user what engine
version they have installed, whether a Kenney pack exists, or what a genre
convention is. Look it up (use `game-assets` to check whether assets exist).
Only ask about things that are a matter of taste or intent.

### Round 1: the root of the tree

These come first because everything else hangs off them:

1. **Pitch**: one sentence, in the form "You are X, doing Y, in order to Z."
2. **Platform and engine**: web (Phaser for 2D, Three.js for 3D) or desktop
   (Godot 4)? Recommend web unless the user needs native performance, Steam
   features, or already knows Godot.
3. **2D or 3D, and camera**: side view, top-down, isometric, first person,
   third person.
4. **Scope**: game jam (48–72 h), weekend prototype, or a small commercial
   game. This sets the size of every later answer.
5. **Reference games**: two or three the user wants it to feel like. That
   says more than any adjective.

### The branches to cover afterwards

Every one of these must be settled or explicitly cut before the GDD is written:

- **Core loop**: what the player does every 5–30 seconds, and why they do it again.
- **The first 30 seconds**: exactly what the player sees and does on launch.
  If this can't be described, the design isn't ready.
- **Verbs and controls**: every player action and its key/button/touch
  mapping. Keyboard + gamepad for desktop, and touch too if the web game
  should work on phones.
- **Fail state and win state**: how a run or level ends, and what happens next
  (restart, checkpoint, meta-progression).
- **Challenge**: what makes it harder over time (enemy count, speed, new
  enemy types, puzzles), and on what curve.
- **Progression and retention**: levels, unlocks, score, upgrades, or none.
- **Game feel**: screen shake, hit-stop, particles, juice budget.
- **Art direction**: style (pixel art at N px, low-poly, flat vector,
  realistic), 4–6 colour palette, readability rules (the player always
  reads against the background, enemies read as enemies), and UI/HUD
  contents and placement.
- **Audio**: SFX list, music mood, and whether there is music at all.
- **Assets**: which free packs fit the style. Check with `game-assets`
  search before recommending a pack.
- **Out of scope**: things the user mentioned that won't be in v1.
- **Genre-specific branches**: for horror or mystery, read `references/horror-design.md`
  and add its interview questions: the core question nobody answers, the spoiler list, the diegetic
  layers, the number of nights, the setting's era and culture, and how each threat moves.

Push back on scope. A jam game has **one** core mechanic done well. If the
answers add up to more than the scope allows, say so and propose what to cut.

## Writing the GDD

When the frontier is empty, summarise the settled decisions in one message
and ask the user to confirm. Once they confirm, fill in `assets/gdd-template.md` and write it to
`GDD.md` in the project root (create the folder if the project doesn't
exist yet).

Rules for the document:

- **Concrete numbers over adjectives.** "Player speed 180 px/s, jump apex
  at 0.35 s" beats "responsive movement". Mark tuning values as starting
  points: `180 px/s (tune)`.
- **The asset list is a table** with the columns: key, description, source
  (a `game-assets` ref like `kenney:pixel-platformer`, or `placeholder`, or `generate`), and
  status. The code later loads assets by these keys.
- **Milestones are playable.** Each one ends with something that can be run
  and screenshotted by `game-playtest`: M1 is always "the core verb on a blank
  screen".
- Keep it under ~2 pages. A GDD nobody rereads is useless.

## After the GDD

Tell the user the next step in one line. It's usually `game-assets` to fetch
the asset list, then building milestone 1. If the `gamedev` skill is
installed, it drives the rest of the pipeline.

## Updating an existing GDD

If `GDD.md` exists, read it first and interview only about what's changing.
Keep the `Changelog` section at the bottom current, with one dated line per
change.
