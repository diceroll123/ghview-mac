// SVGO settings for the language icons. Simple Icons are single-path 24x24 marks, so this mostly trims
// precision and metadata. xmlns and viewBox are kept: AppKit needs both to render the SVG.
export default {
  multipass: true,
  floatPrecision: 2,
  plugins: [
    'preset-default', // SVGO 4 keeps viewBox by default
    'removeTitle',
    'removeDimensions',
    { name: 'removeAttrs', params: { attrs: ['role'] } },
  ],
};
