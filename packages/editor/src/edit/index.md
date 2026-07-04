# edit ops

The engine's mutation surface: pure, node-granular transforms of a `TikzPicture`
that the canvas drives (roadmap workstream 1). See `ops.md` for the contract and the
E1..E5 plan. Callers (the shell) target a frame, apply an op, re-serialize the
document to source, and push it through the code-pane seam.
