() => {
  const MIN_AREA = 400; // skip near-invisible elements (px^2)
  const colorFreq = new Map();
  const typoSamples = [];
  const spacingValues = [];
  const radii = new Set();
  const shadows = new Set();

  function bump(map, key, weight) {
    map.set(key, (map.get(key) || 0) + weight);
  }

  // Headings and CTA-shaped elements carry more weight toward brand/role
  // colors than incidental body text does.
  function weightFor(el, computedStyle) {
    const tag = el.tagName.toLowerCase();
    if (['h1', 'h2', 'h3'].includes(tag)) return 5;
    if (isComponentCandidate(el, computedStyle)) return 5;
    if (['h4', 'h5', 'h6'].includes(tag)) return 3;
    return 1;
  }

  // Interactive/form-shaped elements are candidates for the Components
  // token group (buttons, inputs) — distinct from weightFor's role-color
  // weighting, which also covers headings.
  function isComponentCandidate(el, computedStyle) {
    if (el.matches('button, [role="button"], a[class*="btn"], a[class*="button"], [class*="cta"], input, textarea, select')) {
      return true;
    }

    if (el.tagName !== 'A' || !el.getAttribute('href')) return false;

    const hasPadding = ['paddingTop', 'paddingRight', 'paddingBottom', 'paddingLeft']
      .some((property) => parseFloat(computedStyle[property]) > 0);
    const hasBackground = computedStyle.backgroundColor &&
      computedStyle.backgroundColor !== 'transparent' &&
      computedStyle.backgroundColor !== 'rgba(0, 0, 0, 0)';
    const hasBorder = parseFloat(computedStyle.borderWidth) > 0;

    return hasPadding && (hasBackground || hasBorder);
  }

  function componentKey(el) {
    const tag = el.tagName.toLowerCase();
    const cls = el.className && typeof el.className === 'string'
      ? el.className.trim().split(/\s+/).join('.')
      : '';
    return cls ? `${tag}.${cls}` : tag;
  }

  const componentsByKey = new Map();

  const els = [
    document.documentElement,
    document.body,
    ...document.querySelectorAll('body *'),
  ].filter((el) => {
    const r = el.getBoundingClientRect();
    return r.width * r.height >= MIN_AREA && r.width > 0 && r.height > 0;
  });

  for (const el of els) {
    const cs = getComputedStyle(el);
    const w = weightFor(el, cs);

    if (cs.color && cs.color !== 'rgba(0, 0, 0, 0)') bump(colorFreq, cs.color, w);
    if (cs.backgroundColor && cs.backgroundColor !== 'rgba(0, 0, 0, 0)') {
      bump(colorFreq, cs.backgroundColor, w * 1.5);
    }
    if (cs.borderColor && cs.borderWidth !== '0px' && cs.borderColor !== 'rgba(0, 0, 0, 0)') {
      bump(colorFreq, cs.borderColor, w);
    }

    if (/^h[1-6]$/i.test(el.tagName) || el.tagName === 'BUTTON' || el.matches('p, span, label, a')) {
      typoSamples.push({
        tag: el.tagName.toLowerCase(),
        className: el.className && typeof el.className === 'string' ? el.className.split(' ').slice(0, 2).join(' ') : '',
        fontFamily: cs.fontFamily,
        fontSize: cs.fontSize,
        fontWeight: cs.fontWeight,
        lineHeight: cs.lineHeight,
        letterSpacing: cs.letterSpacing,
      });
    }

    for (const prop of ['marginTop', 'marginBottom', 'marginLeft', 'marginRight', 'paddingTop', 'paddingBottom', 'paddingLeft', 'paddingRight']) {
      const v = cs[prop];
      if (v && v !== '0px') spacingValues.push(v);
    }

    if (cs.borderRadius && cs.borderRadius !== '0px') radii.add(cs.borderRadius);
    if (cs.boxShadow && cs.boxShadow !== 'none') shadows.add(cs.boxShadow);

    if (isComponentCandidate(el, cs)) {
      const key = componentKey(el);
      if (!componentsByKey.has(key)) {
        componentsByKey.set(key, {
          selector: key,
          backgroundColor: cs.backgroundColor,
          textColor: cs.color,
          borderRadius: cs.borderRadius,
          paddingTop: cs.paddingTop,
          paddingRight: cs.paddingRight,
          paddingBottom: cs.paddingBottom,
          paddingLeft: cs.paddingLeft,
          fontSize: cs.fontSize,
          fontWeight: cs.fontWeight,
        });
      }
    }
  }

  const colors = Array.from(colorFreq.entries())
    .sort((a, b) => b[1] - a[1])
    .slice(0, 12)
    .map(([value, weight]) => ({ value, weight }));

  const spacingHistogram = {};
  for (const v of spacingValues) spacingHistogram[v] = (spacingHistogram[v] || 0) + 1;

  return {
    url: location.href,
    colors,
    typography: typoSamples.slice(0, 40),
    spacingHistogram,
    radii: Array.from(radii),
    shadows: Array.from(shadows).slice(0, 10),
    components: Array.from(componentsByKey.values()).slice(0, 10),
  };
}
