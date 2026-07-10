# race_gametool

A new Flutter project.

## Todo:

- [X] In Level editor, use multi layer and only show the block is for that layer.

  - [ ] Function layer (check line and wall) — layer exists; no placeable wall/check-line blocks yet
  - [X] Decoration layer (finish line and other decoration)
  - [X] Track layer
  - [X] Island layer
- [X] 2 Line align to cursor: vertical/horizontal
- [X] Auto island generation.

  - [X] Mark island tiles with 8-direction ports (interior has all 4 diagonals; a concave corner has no diagonal pointing into the notch).
  - [X] In the island Phase 1 page, tally tiles by kind and report set completeness.
  - [X] Basic generator: enabled once the full convex set is present (interior + 4 edges + 4 convex corners).
  - [X] Advanced generator (islands with concave notches): concave corners are placed automatically when authored.
  - [X] When a kind has more than one tile, pick one at random.
  - [X] Auto: grow the island from the track footprint (+4 cells, smoothed) and autotile by each cell's 8-neighbour grass mask.
  - [X] Manual grass brush to paint/erase the 1/0 island region before autotiling.
- [X] Undo
- [X] Confirm before clear all
- [X] Use window manager to create a desktop app with a custom window frame.
- [X] Import map
- [ ] Auto resize in phase 1
- [ ] Drag to stamp in phase 2
- [ ] Remove insert and remove to close in phase 2/track
- [ ] More accuracy in trackpad guesture / tool change automatically
- [X] Fix: autofill, clear.
- [X] Add icon
