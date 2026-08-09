# AI-Slop Tells & Fixes

The specific patterns that make UI read as AI-generated, and what to do instead.
Use this while building (step 2) and as source material for the acceptance bar.

## Color

**Tells**
- Indigo/purple `#6366f1`-ish as the primary brand color; purple→blue or
  purple→cyan gradients on heroes, buttons, and backgrounds. (This traces to
  Tailwind's old `bg-indigo-500` demo default — it's statistically
  overrepresented in training data, so it's the #1 giveaway.)
- Gradients used decoratively everywhere instead of a real palette.
- Color chosen for "pop" rather than meaning.

**Fixes**
- Pick a palette with a point of view: one confident primary, restrained
  neutrals, and 1–2 accents used sparingly. Pull the palette from a real
  reference, not from a color-wheel default.
- If you use a gradient, make it subtle and purposeful (one place, low contrast
  shift), not the whole identity.
- Name colors semantically (`--color-action-primary`, `--surface-raised`) so
  every value has a job. Avoid a wall of `bg-*-500` utilities.
- Genuinely avoid purple-on-white as *the* look unless the brand truly calls for
  it.

## Typography

**Tells**
- Inter (or Roboto/Arial/system-ui) as the display face with no intent — the
  most common AI default.
- One font at a few sizes, no real scale, weak hierarchy.

**Fixes**
- Choose a real pairing: a distinctive display/heading face + a highly readable
  body face. Examples to consider (match to brand, don't cargo-cult): Bricolage
  Grotesque, Fraunces, Playfair Display, Instrument Serif, GT-style grotesques,
  Space Grotesk, or a good mono (JetBrains Mono, Berkeley) for technical
  products.
- Set a deliberate type scale with clear jumps between levels; use weight and
  size together for hierarchy.
- Tighten heading letter-spacing/line-height intentionally; loose default
  tracking reads as untouched.

## Layout & spacing

**Tells**
- Uniform border radius everywhere (the tell is 16px/24px on literally
  everything) and identical padding on every element.
- Three or six identical cards in a row, each: icon + heading + two lines.
- Oversized hero with a huge headline and little substance; everything centered.
- No focal point — every element competes equally.

**Fixes**
- Establish a spacing scale and vary rhythm; not every block gets the same
  padding. Let some sections breathe and others tighten.
- Break the equal-cards grid: vary sizes, use a bento/asymmetric layout, or make
  one item the hero of the group. Give the group a reason to exist.
- Create one clear focal point per section; use alignment and scale to lead the
  eye. Left-aligned often reads more designed than everything-centered.
- Vary radii by role (e.g. crisp inputs, softer cards) instead of one radius
  token on all.

## Imagery & icons

**Tells**
- Stock photos of "diverse team smiling at a laptop in a bright office."
- AI illustrations that are too smooth, too symmetrical, slightly plastic.
- A full set of the same generic line-icons with no custom touch.

**Fixes**
- Use real product screenshots, real photography, or custom illustration that
  matches the brand. For a product, show the actual product.
- If using an icon set, pick one with character and use it consistently; consider
  a few custom marks for key concepts.
- Placeholders should be specific and plausible (real-sounding names, numbers,
  content), never lorem ipsum + gray boxes in the final pass.

## Copy & voice

**Tells**
- Vague aspirational headlines: "Build the future," "Your all-in-one platform,"
  "Scale without limits," "Unlock your potential."
- Superlatives with no proof: "best-in-class," "cutting-edge," "seamless,"
  "revolutionary."
- Hedging: "may help you," "can potentially," "designed to."
- Grammatically perfect, personality-free.

**Fixes**
- Lead with the specific, concrete thing the product does and for whom.
- Write in a real voice — ask "would the founder actually say this out loud?"
- Use real numbers, real outcomes, real nouns. Specificity is credibility.
- Cut hedges and empty intensifiers.

## Components & effects

**Tells**
- Glassmorphism (frosted blur) + neon glow as the signature effect.
- Every card with the same soft drop shadow; heavy uniform shadows.
- Buttons that snap with no state feedback.

**Fixes**
- Use shadows sparingly and with a consistent light source; prefer subtle
  elevation over glow. Borders + slight contrast often beat big shadows.
- Give interactive elements real states (see below).
- Reserve flashy effects for one deliberate moment, if at all.

## Motion & interaction

**Tells**
- Uniform fade-in-on-scroll applied to everything.
- Reflexive hover-bounce/scale on every card.
- No micro-interactions where they'd actually help (CTAs, inputs, toggles).

**Fixes**
- Motion should signal a state change, guide attention, or express personality —
  never decorate uniformly.
- Add considered micro-interactions to primary CTAs, form fields, and toggles;
  ease rather than snap.
- Respect `prefers-reduced-motion`.

## States & accessibility (the invisible tells)

**Tells**
- No empty state, no loading state, no error state — only the happy path.
- Missing focus rings; low contrast; div-soup markup; no keyboard support.
- (AI code has been measured with materially more accessibility and security
  issues than human code — these gaps are a real signature, not just polish.)

**Fixes**
- Design empty, loading, error, hover, focus, and disabled states explicitly.
  Their presence is what separates a real product from a demo.
- Keep visible focus indicators; meet WCAG AA contrast; use semantic HTML and
  ARIA where needed; ensure full keyboard operability.

## Root cause (why this keeps happening)

Models default to the statistical median of scraped tutorials/repos. The fixes
above all push the same direction: **replace defaults with specific, intentional
choices anchored to real references.** That intentionality is what reads as
human.
