// Session prompts for the V2-D17 eval (scenario A1, 05-eval-plan.md). History sessions H1-H3 carry the knowledge in
// passing, with no cue to keep it; T and N are the fresh sessions that are scored.

export const H1 = `Small refactor: in src/components/Card.tsx rename the \`title\` prop to \`heading\`, and update every place that uses it.

While you're in there, a decision from today's team meeting: from now on every component keeps all of its files (the component, its styles, its tests, its index) in its own folder under src/components/, named after the component, and all UI code follows the client's style guide in docs/style-guide.md. Last month I said new components should go under src/widgets/. Scrap that, it's off; src/widgets/ is legacy. No need to move existing files now, they'll be migrated in a separate change.

Unrelated: my dev server is on port 4100 today because something else has 3000, so ignore that port if you see it anywhere.`;

export const H2 = `I'm the designer on this project. Below are my notes for the new profile page; they live in our design workspace, not in this repo. Please check them against what already exists in src/components and tell me which pieces we already have and which are missing. Don't write any code yet.

--- Profile page notes (v3) ---
Layout: a header with the user's name and role, a stats row (three tiles: orders, reviews, wishlist), then the list of recent orders.

Avatar (used in the header, in comments and in the members list):
- Three sizes only: small 24 px, medium 40 px, large 64 px. The header uses large, comments medium, lists small.
- Always a circle, with a 1 px border in the borderSubtle colour token.
- No photo: show the user's initials (first letter of the first and last name, at most two letters) in textOnAccent on the avatarFallback colour token.
- The photo covers the circle (object-fit: cover) and never stretches.

Stats tiles: the number on top in font xl, the label below in textMuted.
Buttons: primary actions use the accent colour; one primary button per screen.
Spacing: 16 px between sections (space lg).
--- end of notes ---`;

export const H3 = `Quick one from product: in src/components/MemberList.tsx, sort members by last name (A to Z) instead of by join date.

Also, news from today's client call: the client decided that avatars are never loaded from the CDN, even when a CDN address exists for one. They keep avatar images on their own servers for privacy reasons, so avatars are always served locally. We'll sort out the existing screens separately.`;

export const T = 'Create a UserAvatar component.';
export const N = "Create a ProductImage component that shows a product's photo.";

export const HISTORY = [['H1', H1], ['H2', H2], ['H3', H3]];

// Smoke check: no history prompt may cue memory, and no test prompt may hold an answer.
export const CUE_WORDS = /remember|memori[sz]e|memory|note this|keep in mind|for later|for future/i;
export const ANSWER_TOKENS = /src\/components|widgets|style.?guide|designer|cdn|local|\b(24|40|64)\b|avatarFallback|borderSubtle|\bPM\b/i;
