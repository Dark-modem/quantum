# Third-party notices

## Design methodology — UnsloP

The Controller UI's visual pass (spacing rhythm, restrained accent, honest
empty/error states, tabular figures, one icon family) adapts the design
methodology from **UnsloP** by Damir Sokolovsky:
https://github.com/heydamir/unslop (CC BY 4.0). The methodology guided the
redline review; no UnsloP code or theme is bundled — the implementation is
Quantum's own tokens.css/enterprise.css on the existing plain HTML/CSS/JS
stack. The product-specific direction (graphite control room, restrained
teal accent, Hub——Node route-health signature) is documented in the design
comment header of `panel/enterprise.css`.
