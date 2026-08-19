# Diagrams

| File | Status |
|---|---|
| `fsm.png` / `fsm.svg` | Three-state control FSM. Original work — safe to publish. |
| `datapath.png` | **To be drawn.** Must be your own drawing of your own datapath. |
| `memory_map.png` | **To be drawn.** Optional; the table in `architecture.md` may be enough. |

## Before adding a diagram

Do not use figures from lecture slides or textbooks. The classic multi-cycle
datapath and its ten-state control FSM are figures from Patterson & Hennessy,
*Computer Organization and Design*, reproduced in the course slides. They are
copyrighted, and republishing them in a public repository under an MIT licence
is a licensing problem regardless of attribution.

They also do not describe this processor. This design has three states rather
than ten, separate instruction and data memories rather than one shared memory,
and no `ALUOut`, `A` or `B` temporaries. A reader who takes the textbook figure
as the architecture will ask questions the RTL cannot answer.

Draw the datapath from your own `Datapath.v`: the blocks that exist, the muxes
that exist, and the control signals your `ControlUnit.v` actually emits.
draw.io or Excalidraw, exported at 2× resolution, is enough.
