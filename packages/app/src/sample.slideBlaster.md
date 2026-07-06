---
title: SlideBlaster
author: You
bibliography: refs.bib
citationStyle: numeric
---

## Welcome {#s1}

```slide
\node[title] (title) at (8,8) {SlideBlaster};
\node[body, below=0.8 of title, text width=11] (intro) {
- LaTeX/TikZ-native slides
- **Markdown**, *LaTeX*, and HTML content
- $\int_0^1 f\,dx$ renders inline
};
\node[note] (tag) at (13,3) {live};
\draw[->] (intro) -- (tag);
```

## Positioning {#s2}

```slide
\node[title] (title) at (8,8) {Positioning};
\node[body, below=0.8 of title, text width=12] (b) {
- Absolute placement with at (x,y)
- Relative placement with below=of
- Arrows connect node anchors
};
```

## Overlays {#s-overlays}

```slide
\node[title] (title) at (8,8) {Overlays and steps};
\node[body, below=0.8 of title, text width=11] (steps) {
\begin{itemize}
\item Everything starts on step 1
\item<2-> Uncovered from step 2
\item<3-> and this one from step 3
\end{itemize}
};
\node[note, overlay={2-}] (tag) at (13,5) {node reveal: from step 2};
\node[body, below=0.6 of steps, text width=11] (inline) {
Inline: \only<2>{only on step 2} and \alert<3>{alert on step 3}
};
\draw[->] (tag) -- (steps);
```

## Tables {#s3}

```slide
\node[title] (title) at (8,8) {Tables};
\node[body, below=0.9 of title] (data) {
\begin{tabular}{lr}
\toprule
Fruit & Qty \\
\midrule
Apples & 3 \\
Pears & 12 \\
Cherries & 40 \\
\bottomrule
\end{tabular}
};
\node[note, right=1.2 of data] (src) {compiled by latexml};
\draw[->] (src) -- (data);
```

## Columns and matrices {#s4}

```slide
\node[title] (title) at (8,8) {Columns and matrices};
\node[body, below=0.9 of title, text width=13] (cols) {
\begin{columns}
\column{0.6}
- Side-by-side content
- Widths are proportional
\column{0.4}
A matrix of cells:
\matrix{1 & 2 \\ 3 & 4}
\end{columns}
};
```

## Related work {#s5}

```slide
\node[title] (title) at (8,8) {Related work};
\node[body, below=0.8 of title, text width=13] (c) {
- Digital typesetting was pioneered by \cite{knuth1984}
- Markup on top of it followed soon after \cite{lamport94}
- Together they remain the standard references \cite{knuth1984, lamport94}
- Numbering is deck-wide; footnotes sit at the slide foot\citefootnote{lamport94}
};
```

## References {#s6}

```slide
\node[title] (title) at (8,8) {References};
\node[body, below=0.9 of title, text width=13] (refs) {
\printbibliography{}
};
```
