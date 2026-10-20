# Kestrel & Finch front-end style guide

Issued by the client's design team. It applies to all UI code in this repository.

1. Colours come only from the theme tokens in `src/theme/tokens.ts` (`tokens.color.*`). No hex values, `rgb()`,
   `hsl()` or named colours in components.
2. Spacing uses the `tokens.space` steps. No raw pixel values for margin, padding or gap.
3. Text sizes use `tokens.font`.
4. Components are function components with a named export and a props interface named `<Name>Props`.
5. Every image has a meaningful `alt` text, or `alt=""` when it is decorative.
6. Every interactive element has an accessible name.
