# AGENTS.md

Instructions for the agent that builds this track in Blender from the TrackScout
field data. Copy this file into your track project. It also serves as
`CLAUDE.md`.

TrackScout is a field-research app: the owner, a human who knows the track
physically, walks it, answers questions, and takes photos. A small server on
their home network collects those, and `tools/export_for_agents.py` merges them
into one document. That document is your ground truth.

## Reading the data

Produce the merged view from a running server:

    python3 tools/export_for_agents.py --base http://your-server:8765 --out export/

It writes `answers_merged.json` and `answers_summary.md`. Local files work in
place of the base URL (see the tool's `--help`).

Each question in the merged document carries: the question's fields (`id`,
`building`, `lat`, `lon`, `context`, `question`, `type`, `options`), its
latest `answer` (or `null` while unanswered), its `photos`, and a `place_key`
(lat/lon rounded to about 1 m). Questions sharing a `place_key` are one place,
the same way the app's All tab groups them. `exported_at` and `generated` are
timestamps; nothing keys on them.

`answers_summary.md` is the same content a person can read: **bold** is a real
answer from the owner, *Don't know* is still open, `WRONG LOCATION` means the
pavement point was wrong.

## The precedence rules

1. **Owner answers override research.** Anything the owner actually said wins
   over documents, street photos, or geodata. If your research says flat
   facade and the owner says three arches, it is three arches. Do not correct
   the owner with better sources. The owner stood there.
2. **`Don't know` stays open.** Model the decision with your best judgment,
   mark it as unconfirmed, and write a new field question for the next round.
   Never present a guess as a settled fact.
3. **A `WRONG LOCATION` comment carries corrected coordinates.** The `comment`
   field holds the `lat, lon` where the owner says the building actually is.
   Use those for the place; treat the old point as superseded. Do not average
   the two.
4. **Photos are reference material, never texture pixels.** Use them for
   facade type, signage, proportions, and lighting decisions. Exception: a
   photo whose owner explicitly shot it for this project and allows the use
   may serve as a texture source. When in doubt, geometry and materials from
   the photo, not its pixels.

## Fields worth using

- `lat`/`lon` on questions, and on photos where present, are WGS-84 pavement
  points: where the owner stood, facing the subject. Anchor your projection
  at one trusted point and convert the rest against it; do not mix datums
  between buildings.
- A photo's `heading_deg` and `pitch_deg` (with `acc_m` for the fix's
  accuracy) let you place the shot relative to its pavement point instead of
  guessing which way it faced.
- `kind` is `storefront`, `sign`, `facade`, `detail`, `night_lighting`, or
  `other`. `light` is `day`, `dusk`, or `night`. Night shots drive emissive
  material (signs, lit windows, rigs); day shots drive surfaces and geometry.
- `set_id`/`set_step` mark a storefront set: a sequence of shots (door,
  window, post). Cross-check them: one known width (a standard door, a window
  module, a post) in one step scales the rest of the set.
- `source` is `camera` (shot on the spot) or `import` (copied from the
  owner's photo library). The reference-only rule applies to both.
- `unattached_photos` are photos with no matching question (capture mode, or
  the question no longer exists). Judge their usefulness; never invent a
  question for one.

## What to do about gaps

- An unanswered question (`answer: null`) is open: model a reasonable default,
  flag it, and write it back as a field question for the next round.
- An answer that contradicts your research stands; log the contradiction for
  the owner to resolve, and do not silently pick a side.
- Write new questions in the shape of `schemas/questions.schema.json` and
  validate them with `python3 tools/validate_questions.py <file>`.
- Never fabricate an answer, and never write one. You read the answer data;
  the owner writes it.
