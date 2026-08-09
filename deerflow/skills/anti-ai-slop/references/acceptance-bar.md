# Anti-Slop Acceptance Bar

Critique the built UI against this list (step 3). Each item is pass/fail. For
every fail, fix the highest-impact one, then re-check. A one-shot build rarely
passes all of these; the loop is the point.

1. **No default-palette giveaway.** Primary look is not indigo/purple, and there
   is no purple→blue / purple→cyan gradient carrying the identity.
2. **Intentional type.** Display face is not a bare Inter/Roboto/Arial default;
   there's a real pairing and a deliberate scale with clear hierarchy.
3. **Varied rhythm.** Radii, padding, and card sizes are not all identical;
   there is a visible focal point rather than N equal boxes.
4. **Not the icon-card cliché.** No three/six identical icon+heading+two-lines
   cards presented as the main content without variation or reason.
5. **Real content.** Copy and imagery are specific (real screenshots/plausible
   content), not stock "team at laptop" or lorem placeholders in the final pass.
6. **Human copy.** Headlines are concrete, in a real voice; no "build the
   future / all-in-one / cutting-edge" filler and no hedging.
7. **Effects with restraint.** No glassmorphism-glow signature; shadows are
   subtle and consistent, not uniform heavy drop shadows on everything.
8. **Purposeful motion.** Animations signal state or guide attention; no uniform
   fade-ins or reflexive hover-bounce; reduced-motion respected.
9. **States designed.** Empty, loading, error, hover, focus, and disabled states
   exist for the relevant components — not just the happy path.
10. **Accessible.** Visible focus rings, WCAG AA contrast, semantic markup,
    keyboard operable.
11. **Anchored to a reference.** The design reflects specific real references
    (ideally pulled from Refero), not a generic "modern SaaS" memory.
12. **Not over-corrected.** Distinctiveness didn't tip into unusable "weird for
    weird's sake"; it's still clean, appropriate, and easy to use.

If 11 is failing, the fastest fix is usually to go back to step 1 and pull a real
reference rather than pushing pixels.
