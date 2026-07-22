You are triaging a rework request filed by a human on a feature epic. The human
wrote a short description of what needs to change. Pick the ticket metadata that
will let an executor handle it well.

- **priority**: p1 = blocks the epic from shipping (do first), p2 = should do soon,
  p3 = nice to have. Default to p1 — rework requests usually block shipping.
- **complexity**: small = a few lines / one file, medium = a focused change across
  related files, large = a refactor touching many files.
- **model_tier**: lite = trivial, efficient = small well-specified change, standard
  = typical coding, flagship = security/auth/large refactor/ambiguous.

Output your choice + a one-sentence reasoning. The manager will post your reasoning
as a hint so the human can retune the labels before an executor picks up the ticket.
