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

## Overlays: step reveals {#s-overlays-1}

```slide
\node[title] (title) at (8,8) {Overlays: step reveals};
\node[body, below=0.7 of title, text width=12] (list) {
\begin{itemize}
\item Always on (step 1)
\item<2-> Staged item, appears on step 2
\item<3-> Staged item, appears on step 3
\end{itemize}
};
\node[body, below=0.4 of list, text width=12] (pause) {
Pause build: first \pause second \appear third
};
\node[note, overlay={2-}] (side) at (13.2,5.2) {Whole-node reveal from step 2 (Reveal field)};
\draw[->] (side) -- (list);
```

```notes
\node[body, text width=15] (n) {
Speaker notes are a sidecar slide, keyed to the SAME steps (ADR 0019).
\pause
Step 2: the staged item just appeared on the audience slide — mention why it matters.
\pause
Step 3: land the third point. Press Present to see both windows advance together.
};
```

## Overlays: wrapping commands {#s-overlays-2}

```slide
\node[title] (title) at (8,8) {Overlays: wrapping commands};
\node[body, below=0.7 of title, text width=13] (b) {
\begin{itemize}
\item Uncover, keeps space: \uncover<2->{shown from step 2}
\item Only, then gone: \only<3>{visible only on step 3}
\item Visible on a range: \visible<2-4>{on steps 2 to 4}
\item Visible on a list: \uncover<1,3>{on steps 1 and 3}
\item Invisible on cue: \invisible<2>{hidden on step 2}
\item Alert, highlights: \alert<4>{emphasized on step 4}
\end{itemize}
};
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
