# Horror and mystery: design rules learned from player feedback

Read this when the GDD's genre is horror, mystery, thriller, or anything whose payoff is a
question the player isn't supposed to answer too early. Every rule comes from THE ONES (Godot 4,
first-person horror, rural Japan 1998, four days and four nights). Each one is backed by a quote from the
user who played it. The quotes are kept in Spanish as said, with a translation.

## Ambiguity is the product

- **Nothing answers the core question for the player**: not the UI, the trailer or the store page.
  No evidence board, no "mark this human/alien" mechanic, no concluding journal.
  > "No tiene sentido que uno marque si es humano u otro… simplemente juega y descubre"
  > (There's no point marking whether it's human or not… just play and find out.)
- **Keep a spoiler list in the GDD**: every creature, reveal, twist and ending. The trailer, the
  landing page, screenshots and the itch page are all checked against it (`game-trailer` Rule 0).
  > "creo que el trailer no deberia mostrar cosas, estas haciendo spoiler, siento que es muy obvio"
  > (The trailer shouldn't show things. You're spoiling it, it feels too obvious.)
- **The threat is a family, not a species.** Use 3-4 unrelated forms, each with its own role, so the player
  can't build a mental model. In THE ONES: a tall near-human for reflections and tape-only sightings,
  a quadruped for the grass and forest edge, a crawler for close scares (shoji gap, roof, under the
  house), a flyer seen only far away, and two giants (one machine, one living).
  > "como es the ones, no existe un solo tipo, asi confunde mas al jugador"
  > (It's "the ones", there isn't a single kind, that confuses the player more.)

## Movement and physicality must survive a close-up

- **Wrong movement creates dread, and smooth sliding reads fake.** Use blink/teleport (2-4 glitch frames plus
  static, reappearing closer), stop-motion stutter at 6-10 irregular fps, sharp head twitches,
  sudden freeze-stares.
  > "Los movimientos deben ser erraticos, como teletransportados en algunos casos"
  > (Movements should be erratic, like teleporting in some cases.)
  > "el movimiento del alien… parece solo arrastrarse en lugar de caminar"
  > (The alien seems to drag itself instead of walking.) Fix: move at the walk clip's real speed.
- **A silhouette or shadow must be the real monster**, never a shader-drawn stand-in. THE ONES renders
  the animated model to a hidden orthographic camera and projects it onto the paper screens
  (`godot-field-notes/references/rendering.md`).
  > "parece que ese alien es falso, no es el monstro real bipedo, deberia serlo"
  > (That alien looks fake, it isn't the real two-legged monster. It should be.)
- **Props are physically held.** Lanterns hang from a bamboo pole parented to the hand bone, with
  pendulum swing. People in news clips and videos are rigged 3D models, never flat cards.
  > "las lamparas no estan agarradas a las manos" / "las personas no son modelos 3D"
  > (The lanterns aren't held in the hands / the people aren't 3D models.)
- Check these in close-up stills **before** showing the user.

## Depth comes from diegetic layers, not deduction UI

Ask about these in the GDD interview. Each one is a way the world tells the player something without the
game saying it:

- TV news: anchor, aged photos, "viewer video" clips. Make them era-authentic.
  > "las noticias de la TV sean mas realistas… fotos… con un filtro para que se vean antiguas…
  > un video como el de la pelicula de Señales"
  > (Make the TV news more realistic… photos with an aging filter… a clip like the one in *Signs*.)
- Found VHS tapes, an answering machine, neighbour reports, a dog barking at nothing,
  footsteps on the roof while sleeping, lights in the sky through a window.
- A reveal clip of half a second or less, with a sting, in the style of the clip in *Signs*.
  > "Falta… noticias de TV, grabaciones, Caminadas en el techo… Ladridos del perro, Reporte de vecinos"
  > (Missing: TV news, recordings, steps on the roof… the dog barking, neighbour reports.)

## Structure

- **Several nights.** One night is too short for narrative horror. THE ONES moved to four days and four nights.
  > "Creeria que sea mas de 1 noche… Tipo 4 noches" (I'd make it more than one night… like four.)
  > "demasiado corto" (too short)
- Death is possible.
- **A cinematic, skippable prologue** of about 90 s. Without it, the opening felt dry.
  > "al iniciar, deberia de haber una introduccion… muy seco"
  > (There should be an introduction at the start… it's very dry.)
- **Ask about the setting and culture early.** It changes everything downstream.
  > "prefiero que sea en Japon… da mas la pega" (I'd rather it be in Japan… it hits harder.)

## Readability and onboarding

- Make controls obvious: key-glyph icons (Kenney Input Prompts, CC0) inside prompts and dialogue, and
  highlighted keywords (bold, italic, colour). Dialogue at about 24-30 px at 1080p.
  > "los controles tienen que ser obvios… Iconos dentro del cuadro de dialogo"
  > (The controls have to be obvious… icons inside the dialogue box.)
- Context cursor icons: open hand = use, closed hand = grab, eye = inspect, bubble = talk, door.
- **Lots of flavour interactables with throwaway text** (THE ONES has about 40). They make the place feel alive.
  > "aunque sea información tonta, eso le da vida" (even if it's silly information, it brings it to life)
- A map on a key, showing today's tasks.

## Period fidelity

- **The UI matches the era.** A modern sans font and glass panels read as wrong in 1998.
  > "siento que los menus tambien se ven muy modernos (incluida la fuente)"
  > (The menus look too modern too, including the font.)
  For a 1998 setting: a VHS on-screen menu (blue box, VT323 font, ▶ cursor, scanlines, PLAY/counter/date),
  typewriter-paper dialogue (Courier Prime), mincho titles (Shippori Mincho), DotGothic16.
- **Stylization never costs legibility.** The analog/found-footage filter's first pass was "almost
  invisible, too blurred". The fix: subtle defaults, a 0-100% slider in Settings (default 70%), never
  applied to UI or subtitles, and before/after stills shown to the user.
  > "casi no se ve, esta demasiado difuminado" (You can barely see, it's too blurred.)
- Voices in the setting's language, with subtitles. UI in the players' languages.
- An adaptive score (drone → tension → climax), ducking under voice, with silence before scares.

## Density

Sparse reads fake. Use dense forest, real tree models, and ground variety (grass, dirt, rocks, pebbles).
> "los arboles se ven muy falsos… todo el lugar muy vacio" (The trees look fake… the whole place feels empty.)
> "el estilo del suelo… pasto, rocas, piedritas" (The ground… grass, rocks, little stones.)

## Choosing models with the user

When the user dislikes a model, **don't pick a replacement alone**. Build a visual catalog (one numbered
contact sheet, optionally an HTML page with codes M1…Mn / G1…Gn, verified licence, triangle count, rig, honest
note) and let them choose by code: "M3, M2, M13 y G7". Then show the integrated result as a
screenshot sheet and ask "¿son los que esperabas?" (are these what you expected?). The exception is when they
delegate explicitly ("busca uno mejor… has un research", find a better one, do the research): research,
pick, and still show comparison sheets. The procedure is in
`game-assets/references/model-selection.md`.

## Questions to add to the interview (horror/mystery)

- What is the core question, and who or what must never answer it?
- What's on the spoiler list?
- Which diegetic layers deliver information (TV, tapes, phone, neighbours, animals, sky)?
- How many days and nights, and can the player die?
- Setting, era and culture, and what that implies for the UI, fonts and language of voices.
- How does each threat move, and where does each one appear?
