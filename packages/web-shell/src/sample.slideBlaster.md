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
