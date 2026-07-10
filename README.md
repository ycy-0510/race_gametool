# race_gametool

A new Flutter project.

## Todo:
- [x] In Level editor, use multi layer and only show the block is for that layer.
    - [ ] Function layer (check line and wall) — layer exists; no placeable wall/check-line blocks yet
    - [x] Decoration layer (finish line and other decoration)
    - [x] Track layer
    - [x] Island layer
- [ ] 2 Line align to cursor: vertical/horizontal
- [ ] Auto island generation.
    - [x] Mark island tiles with 8-direction ports (interior has all 4 diagonals; a concave corner has no diagonal pointing into the notch).
    - [x] In the island Phase 1 page, tally tiles by kind and report set completeness.
    - [x] Basic generator: enabled once the full convex set is present (interior + 4 edges + 4 convex corners).
    - [x] Advanced generator (islands with concave notches): concave corners are placed automatically when authored.
    - [x] When a kind has more than one tile, pick one at random.
    - [x] Auto: grow the island from the track footprint (+4 cells, smoothed) and autotile by each cell's 8-neighbour grass mask.
    - [ ] Manual grass brush to paint/erase the 1/0 island region before autotiling.
- [ ] Use window manager to create a desktop app with a custom window frame.
