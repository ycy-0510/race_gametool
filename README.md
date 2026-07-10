# race_gametool

A new Flutter project.

## Todo:
- [x] In Level editor, use multi layer and only show the block is for that layer.
    - [ ] Function layer (check line and wall) — layer exists; no placeable wall/check-line blocks yet
    - [x] Decoration layer (finish line and other decoration)
    - [x] Track layer
    - [x] Island layer
- [ ] Auto island generation.
    - [x] Mark island tiles with 8-direction ports (interior has all 4 diagonals; a concave corner has no diagonal pointing into the notch).
    - [x] In the island Phase 1 page, tally tiles by kind and report set completeness.
    - [ ] Basic generator: enabled once the full convex set is present (interior + 4 edges + 4 convex corners).
    - [ ] Advanced generator (islands with concave notches): enabled when the 4 concave corners are also present.
    - [ ] When a kind has more than one tile, pick one at random.
    - [ ] Grass brush to paint the 1/0 island region, then auto-place tiles by each cell's 8-neighbour grass mask.
- [ ] Use window manager to create a desktop app with a custom window frame.
