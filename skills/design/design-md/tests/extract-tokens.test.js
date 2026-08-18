const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const vm = require('node:vm');

const extractSource = fs.readFileSync(
  path.join(__dirname, '..', 'references', 'extract-tokens.js'),
  'utf8'
);

function createElement(tagName, computedStyle, options = {}) {
  return {
    tagName,
    className: options.className || '',
    getAttribute: (name) => options.attributes?.[name] || null,
    getBoundingClientRect: () => ({ width: 100, height: 100 }),
    matches: (selector) => options.matches?.(selector) || false,
    computedStyle,
  };
}

test('extracts page colors defined only on the html and body roots', () => {
  const transparent = 'rgba(0, 0, 0, 0)';
  const baseStyle = {
    color: transparent,
    backgroundColor: transparent,
    borderColor: transparent,
    borderWidth: '0px',
    borderRadius: '0px',
    boxShadow: 'none',
    marginTop: '0px',
    marginBottom: '0px',
    marginLeft: '0px',
    marginRight: '0px',
    paddingTop: '0px',
    paddingBottom: '0px',
    paddingLeft: '0px',
    paddingRight: '0px',
  };
  const documentElement = createElement('HTML', {
    ...baseStyle,
    backgroundColor: 'rgb(12, 34, 56)',
  });
  const body = createElement('BODY', {
    ...baseStyle,
    color: 'rgb(240, 240, 240)',
  });
  const context = {
    document: {
      documentElement,
      body,
      querySelectorAll: () => [],
    },
    getComputedStyle: (element) => element.computedStyle,
    location: { href: 'https://example.test/' },
  };
  const extractTokens = vm.runInNewContext(`(${extractSource})`, context);

  const result = extractTokens();
  const colorValues = Array.from(result.colors, ({ value }) => value);

  assert.deepEqual(
    colorValues,
    ['rgb(12, 34, 56)', 'rgb(240, 240, 240)']
  );
});

test('extracts a visually button-shaped link without naming-convention classes', () => {
  const transparent = 'rgba(0, 0, 0, 0)';
  const baseStyle = {
    color: transparent,
    backgroundColor: transparent,
    borderColor: transparent,
    borderWidth: '0px',
    borderRadius: '0px',
    boxShadow: 'none',
    display: 'block',
    fontFamily: 'Inter',
    fontSize: '16px',
    fontWeight: '400',
    lineHeight: '24px',
    letterSpacing: 'normal',
    marginTop: '0px',
    marginBottom: '0px',
    marginLeft: '0px',
    marginRight: '0px',
    paddingTop: '0px',
    paddingBottom: '0px',
    paddingLeft: '0px',
    paddingRight: '0px',
  };
  const documentElement = createElement('HTML', baseStyle);
  const body = createElement('BODY', baseStyle);
  const cta = createElement(
    'A',
    {
      ...baseStyle,
      color: 'rgb(255, 255, 255)',
      backgroundColor: 'rgb(37, 99, 235)',
      borderRadius: '8px',
      display: 'inline-flex',
      fontWeight: '600',
      paddingTop: '12px',
      paddingBottom: '12px',
      paddingLeft: '24px',
      paddingRight: '24px',
    },
    {
      attributes: { href: '/contact' },
      className: 'inline-flex items-center justify-center',
      matches: (selector) => selector.split(',').some((part) => {
        const candidate = part.trim();
        return candidate === 'a' || candidate === 'a[href]';
      }),
    }
  );
  const context = {
    document: {
      documentElement,
      body,
      querySelectorAll: () => [cta],
    },
    getComputedStyle: (element) => element.computedStyle,
    location: { href: 'https://example.test/' },
  };
  const extractTokens = vm.runInNewContext(`(${extractSource})`, context);

  const result = extractTokens();

  assert.equal(result.components.length, 1);
  assert.equal(result.components[0].selector, 'a.inline-flex.items-center');
  assert.equal(result.components[0].backgroundColor, 'rgb(37, 99, 235)');
  assert.deepEqual(
    {
      top: result.components[0].paddingTop,
      right: result.components[0].paddingRight,
      bottom: result.components[0].paddingBottom,
      left: result.components[0].paddingLeft,
    },
    { top: '12px', right: '24px', bottom: '12px', left: '24px' }
  );
});
