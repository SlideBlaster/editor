# tikz (barrel)

The picture round-trip: `parsePicture` (source -> model) and `serializePicture`
(model -> canonical source), plus derived option views. The two functions are
inverse for canonical input and underpin the document round-trip invariants.
