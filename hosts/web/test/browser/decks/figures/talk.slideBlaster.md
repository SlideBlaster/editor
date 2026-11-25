---
title: TikZ figures
---

## Trust

\figure[width=13]{figures/trust.tikz}

## Arch

\figure[width=12]{figures/arch.tikz}

## Background

\figure{figures/background.tikz}

## Inline

```tikz
\node[draw, rounded corners, fill=blue!10] (a) at (0,0) {one};
\node[draw, circle, fill=orange!20] (b) at (3,1) {$x^2$};
\draw[->, thick] (a) to[bend left] node[above] {goes} (b);
```

## Tips

```tikz
\draw[->] (0,3) -- (3,3) node[right] {to};
\draw[-latex] (0,2.5) -- (3,2.5) node[right] {latex};
\draw[-stealth, thick] (0,2) -- (3,2) node[right] {stealth};
\draw[{Stealth[length=4mm]}-{Latex[open]}] (0,1.5) -- (3,1.5) node[right] {big};
\draw[|-|] (0,1) -- (3,1) node[right] {bars};
\draw[o-*, red] (0,0.5) -- (3,0.5) node[right] {dots};
\node[draw, fill=white, blur shadow, rounded corners] at (6,2.5) {blur};
\node[draw, fill=yellow!30, drop shadow] at (6,1) {drop};
```
