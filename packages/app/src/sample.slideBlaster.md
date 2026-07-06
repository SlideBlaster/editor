---
title: SlideBlaster
author: You
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
