// After inserting a new tree, execute settlePrototypeParents through the Pen
// MCP. In a subsequent call, run fitPrototypeText after native layout resolves.
// Pen can retain root-layer render state on freshly inserted descendants until
// their parent is explicitly reaffirmed. Get() alone can look correct while the
// screenshot is blank and resolved descendant y positions include a 50px offset.
function settlePrototypeParents(roots) {
  for (const root of roots) {
    const children = Get(root, (node, ctx) => ctx.parentCtx
      ? {id: node.id, parent: ctx.parentCtx.node.id} : undefined);
    for (const child of children) Move(child.id, child.parent);
  }
}

// Browser line rectangles remain authoritative. Each line is a separate text
// node, so native lineHeight=1 does not change the source multiline spacing.
function fitPrototypeText(roots) {
  for (const root of roots) {
    const focus = [];
    Get(root, (node, ctx) => {
      if (node.metadata?.type === 'prototype-element') {
        const rect = node.metadata.rect;
        Update(node.id, {width: Math.ceil(rect.width), height: Math.ceil(rect.height)});
      }
      if (node.name === 'Encoder focus') {
        let x = node.x || 0, y = node.y || 0, parent = ctx.parentCtx;
        while (parent && parent.node.id !== root) {
          x += parent.node.x || 0; y += parent.node.y || 0; parent = parent.parentCtx;
        }
        focus.push({id: node.id, x, y});
      }
      if (node.metadata?.type !== 'prototype-text') return;
      const {rect, align} = node.metadata;
      const anchor = align === 'center' ? 0.5 : align === 'right' || align === 'end' ? 1 : 0;
      Update(node.id, {
        x: Math.max(0, rect.x + (rect.width - ctx.bounds.width) * anchor),
        y: rect.y + (rect.height - ctx.bounds.height) / 2,
      });
    });
    for (const item of focus) {
      Move(item.id, root); Update(item.id, {x: item.x, y: item.y});
    }
    Update(root, {layout: 'none', width: 1920, height: 1080});
  }
}
