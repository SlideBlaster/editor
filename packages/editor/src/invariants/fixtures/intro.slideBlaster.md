---
title: Intro
---

## Intro {#s1}

```slide
\node[title] (title) {};
\node[body, below=0.7 of title, text width=12] (intro) {
- point one
- point two
};
\node[note] (o2) at (10,3) {$\int_0^1 f$};
\draw[->] (intro) -- (o2);
```
