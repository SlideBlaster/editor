---
slideblaster: 1
title: Step three
---

## Arrows {#arrows}

```slide
\node[draw, fill=yellow!30] (a) at (2.5,5.5) {Alpha};
\node[draw, fill=blue!15] (b) at (7,5.5) {Beta};
\node[draw, fill=green!20] (c) at (12,3.5) {Gamma};
\node[draw, rotate=30] (d) at (4,2) {Delta};
\node[draw] (e) at (12.5,6.2) {Eps};
\draw[->] (a) -- node[auto] {straight} (b);
\draw[->, thick] (b) -| node[near end, right] {elbow} (c);
\draw[->, dashed] (a) |- node[auto, swap] {vh} (d);
\draw[<->] (b) to[bend left=40] node[auto] {$x^2$} (e);
\draw[->] (d.east) to[out=0, in=180] node[fill=white] {on it} (c.west);
\draw[->] (e.south) -- (c.north);
```

## Edit {#edit}

```slide
\node[draw] (p) at (3,5) {P};
\node[draw] (q) at (9,3) {Q};
\draw[->] (p) -- (q);
```
