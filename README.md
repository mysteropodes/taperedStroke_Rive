# taperedStroke_Rive

A Luau **path effect** script for [Rive](https://rive.app) that turns a stroke into a tapered shape: define a **start width** and an **end width**, and the script builds the tapered outline along the path. Curves (cubic tangents) and multi-point paths are supported.

> ⚠️ This effect outputs a **filled shape**, so it must be applied on a **Fill**, not on a Stroke.

---

## Installation

1. Add a **Script asset** to your Rive file and paste the contents of [`TaperedStrokeEffects.lua`](TaperedStrokeEffects.lua).
2. Select the **Path** you want to taper, add a **Fill** to it, then add this script as a **Path Effect**.
3. Tune the inputs in the inspector.

---

## Inputs

| Input | Type | Default | Description |
|-------|------|---------|-------------|
| `startWidth` | number | 10 | Diameter at the first point of the path. |
| `endWidth` | number | 80 | Diameter at the last point of the path. |
| `curveSteps` | number | 20 | Discretization quality for cubic curves (higher = smoother). |
| `flip` | bool | false | Manually swap start/end if the taper points the wrong way (see below). |
| `useAnchor` | bool | false | Enable position-anchoring to keep start/end stable (see below). |
| `anchorStartX` / `anchorStartY` | number | 0 | Position of the **first** authored vertex (data-bind these). |
| `anchorEndX` / `anchorEndY` | number | 0 | Position of the **last** authored vertex (data-bind these). |
| `trimStart` | number | 0 | Trim path start, in **percent** (0–100). |
| `trimEnd` | number | 100 | Trim path end, in **percent** (0–100). |
| `trimOffset` | number | 0 | Shifts the trim window along the path, in percent. |
| `debug` | bool | false | Prints debug info to the console. |

---

## The "flip" problem (important)

When you move a path point, Rive may internally **reverse the order** of the path commands (it normalizes the contour winding for filling). When that happens, a naive tapered stroke **flips**: `startWidth` jumps to the other end.

A path effect cannot reliably detect this on its own: it only receives the already-reordered path, and the Rive API (`NodeReadData` / `PathData`) exposes **no winding, no authored vertex order, and no stable point identity**. So there is no automatic, foolproof fix from inside the effect.

There are **two ways** to handle it:

### Option A — Manual flip (simplest)
Leave `useAnchor = false`. The taper follows the raw path order. If it ever points the wrong way, just toggle **`flip`**.

### Option B — Position anchoring (stable, recommended)
Give the script a **stable external reference** via data binding, so it always knows which end is the real start — even when Rive reorders the path.

1. In your **View Model**, create 4 number properties, e.g. `startX`, `startY`, `endX`, `endY`.
2. **Data-bind** them to the positions of the **first** and **last** authored vertices of the path.
3. Set **`useAnchor = true`**.
4. **Data-bind** the effect inputs: `anchorStartX/Y` ← `startX/Y`, `anchorEndX/Y` ← `endX/Y`.
5. If the taper is reversed, toggle **`flip`** once.

**How it works:** the script compares the *vector* `start→end` from the anchors with the *vector* `firstPoint→lastPoint` of the path it receives. Because it uses a **difference of positions**, any translation between the vertex space and the effect space cancels out — so it works without needing to know the transform, and it stays stable when Rive reorders the path.

*Limitation:* this assumes the vertex→effect transform is mostly a translation (or a rotation < 90°). If you rotate the whole path ~180°, just correct with `flip`.

---

## Trim path

Three inputs let you reveal only a portion of the tapered shape, measured in **arc length** (percent of total length):

- `trimStart` / `trimEnd` — keep the `[start, end]` portion (0–100).
- `trimOffset` — slide that window along the path.

The taper stays **anchored to the full path** (trimming reveals a sub-section of the existing tapered shape), and the trim is measured in the **same orientation as the taper**, so it does **not** flip when Rive reorders the path. If `trimEnd ≤ trimStart`, nothing is drawn.

---

## Notes

- The radius is **clamped to the local curvature radius** in tight turns, so the inner edge can't fold over itself (no holes/notches). The stroke thins automatically where the curve is tighter than its half-width.
- Best results on **open** paths.
