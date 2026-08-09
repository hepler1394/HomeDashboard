# Stack-specific anti-slop notes

Concrete moves for the stacks the user works in. The rules in
`ai-slop-checklist.md` apply everywhere; this is how to enforce them per stack.

## React + Tailwind

Tailwind is where slop shows up most, because its defaults *are* the slop.

- **Define a real theme in `tailwind.config` (or `@theme` in v4).** Override the
  default palette with brand colors and semantic names; don't scatter raw
  `bg-indigo-500`/`bg-blue-600` utilities through JSX.
- **Set a custom font stack** in the theme (`fontFamily`) and load the real
  faces (next/font, Fontsource, or `@font-face`). Don't leave the Inter/system
  default.
- **Tokenize radius and spacing** and vary them by role instead of slapping
  `rounded-2xl p-6` on everything.
- Build a small set of real components (Button with states, Card variants,
  Input with focus/error) so defaults can't reassert as pages scale.
- Watch for the reflexive `hover:scale-105 transition` on every card — remove it
  unless it's earning its place.

## Next.js / full app

- Everything above, plus: use `next/font` to self-host the chosen faces (avoids
  FOUT and the system-font fallback that reads as unstyled).
- Design real empty/loading/error states using route-level `loading.tsx` /
  `error.tsx` and skeletons — AI output usually ships only the happy path.
- Keep server/client component boundaries from flattening the design system;
  centralize tokens.

## Plain HTML / CSS / JS

- Put everything in CSS custom properties up front (`--color-*`, `--space-*`,
  `--radius-*`, `--font-*`) so choices are intentional and consistent.
- Load real fonts via `@font-face` or a font host; set a modular type scale with
  `clamp()` for fluid, deliberate sizing.
- Hand-author focus styles and states rather than relying on browser defaults;
  keep semantic elements (`button`, `nav`, `main`, headings in order).

## No-code / builders (Framer, Webflow, Lovable, v0, etc.)

- These lean hardest on the generic template look — treat their first output as a
  starting draft, not the deliverable.
- Immediately swap the default font pairing and the template's accent color;
  replace stock imagery with real screenshots/photos.
- Break the equal-cards / big-centered-hero template rhythm; introduce one
  asymmetric or bento section.
- For AI builders (v0/Lovable), give explicit constraints and a Refero reference
  in the prompt, and explicitly prohibit the defaults (no purple gradient, not
  Inter, no three identical cards).
