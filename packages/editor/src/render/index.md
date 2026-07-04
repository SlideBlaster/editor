# render

The render layer (ADR 0014, engine track B). `renderContent` produces the HTML
content layer of the layered DOM. B3 adds the SVG geometry layer (node borders, `\draw`
paths/arrows) and the slide -> pixel transform, then stacks content over geometry.
