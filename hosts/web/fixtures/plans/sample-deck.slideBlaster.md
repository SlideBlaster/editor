---
slideblaster: 1
title: "P4Check"
subtitle: "Branching-time model checking for P4"
authors: Tommaso Pacciani
institute: University of Amsterdam
date: 2026-11
theme: fns
aspect: 16:9
bibliography: refs.bib
citation-style: numeric
preamble: |
  \definecolor{palBlue}{HTML}{1F4E79}
  \definecolor{palGreen}{HTML}{2E7D32}
  \newcommand{\defn}[2]{\sbbox[fill=palBlue!10, title fill=palBlue]{Definition: #1}{#2}}
  \newcommand{\Reach}{\mathsf{Reach}}
---

## Why verify data planes? {#why}

- Testing shows the presence of bugs, not their absence \citefootnote{dijkstra1970}
- A P4 program is a state machine over packets <2->
- We check $\mathcal{M} \models \mathsf{AG}\,\neg\mathit{bad}$ <3->

\defn{Safety}{No reachable state satisfies $\mathit{bad}$.}<4->

```notes
Open with the outage story. Step 3 is the pivot to model checking.
```

## The program {#prog}

::: columns
:::: column 55%
```p4 {2|3-4}
control Ingress(inout headers h) {
  table fwd { key = { h.ipv4.dst: lpm; } actions = { route; drop; } }
  apply {
    fwd.apply();
  }
}
```
::::
:::: column 45%
\begin{block}{Observation}
Table contents are \only<1>{fixed}\only<2>{symbolic} during checking.
\end{block}
::::
:::

## Architecture {#arch}

\figure[width=14]{figures/p4checkarch.tikz}

## Results {#results}

| Benchmark | States | Time (s) |
|---|---:|---:|
| basic_tunnel | 1 204 | 0.8 |
| load_balance | 48 911 | 12.3 |

Compared to the state of the art \cite{p4ltl,bf4}.

```slide
\node[sbbox, fill=palGreen!15] (tk) at (12.5,2) {$\Reach$ is decidable here};
\draw[->] (tk) -- (12.5,4);
```

## References {#refs}

\bibliography
