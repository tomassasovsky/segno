# FX action and library alignment (#1118)

Bring two horizontal layouts back to the accepted Current UX frames in
`segno-ui.pen`. The design remains unchanged.

The Effects context row currently divides flexible space between its label and
a spacer. Short labels leave Reorder and Add effects floating away from the
right edge. Give the leading label and optional monitoring or part controls one
expanded group; keep the label flexible inside it. Actions then end at the
36-pixel right inset while leading controls remain beside their labels.

The Add effects artwork grid is 1660 pixels wide, centered in the 1920-pixel
canvas. Constrain only that grid; retain its existing card sizes and spacing.
Keep the title, outer list and My presets page at their existing 36-pixel inset.
Do not move every subpage to the artwork's inset.

Validation compares six affected author renders with the accepted current
frames, including a separate render of the complete bundled catalogue. Inspect
before updating the six affected baselines; leave the other five baselines
unchanged. Run existing FX behavior tests, strict analysis, formatter and Bloc
lint. Author image comparison is separate from CI, which skips these local-font
screenshots. Independent review and green current-head CI precede readiness;
merging remains a human decision.
