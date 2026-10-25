import 'dart:convert';

/// Runs inside the preview document. Responsive pages keep their layout and
/// vertical scrolling; fixed-width pages shrink only enough to fit the width.
/// A standalone SVG uses its own viewBox and fits both viewport dimensions.
const previewAutoFitScript = r'''
(() => {
  if (window.__expertPreviewFit) { window.__expertPreviewFit(); return; }
  let manual = null, original = null, svg = null, svgOriginal = null;
  let scheduled = false;
  function fit() {
    const root = document.documentElement;
    const rootSvg = root && root.tagName && root.tagName.toLowerCase() === 'svg';
    const body = document.body || (rootSvg ? root : null);
    if (!body) return;
    if (!original) {
      original = {zoom:body.style.zoom, width:body.style.width,
        margin:body.style.margin, height:body.style.height,
        display:body.style.display, placeItems:body.style.placeItems,
        padding:body.style.padding, overflow:body.style.overflow};
      const children = Array.from(body.children).filter(e =>
        !['SCRIPT','STYLE','LINK'].includes(e.tagName.toUpperCase()));
      if (rootSvg || (children.length === 1 && children[0].tagName.toLowerCase() === 'svg')) {
        svg = rootSvg ? root : children[0];
        const box = svg.viewBox && svg.viewBox.baseVal;
        const pixels = value => /^\s*\d+(?:\.\d+)?(?:px)?\s*$/i.test(value || '')
          ? parseFloat(value) : 0;
        const w = pixels(svg.getAttribute('width'));
        const h = pixels(svg.getAttribute('height'));
        if (!box || !box.width || !box.height) {
          if (w > 0 && h > 0) {
            svg.setAttribute('viewBox', '0 0 ' + w + ' ' + h);
          } else {
            // Percentage/physical units are not SVG coordinate dimensions.
            // Use real painted geometry if available instead of fabricating 100x100.
            try {
              const bounds = svg.getBBox();
              if (bounds.width > 0 && bounds.height > 0)
                svg.setAttribute('viewBox', [bounds.x,bounds.y,bounds.width,bounds.height].join(' '));
            } catch (_) {}
          }
        }
        svgOriginal = {width:svg.style.width,height:svg.style.height,
          maxWidth:svg.style.maxWidth,maxHeight:svg.style.maxHeight};
      }
    }
    const vw = rootSvg ? window.innerWidth : (root.clientWidth || window.innerWidth);
    const vh = rootSvg ? window.innerHeight : (root.clientHeight || window.innerHeight);
    if (!(vw > 0 && vh > 0)) return;
    if (svg && manual === null) {
      Object.assign(body.style,{zoom:'1',width:'100%',height:vh+'px',margin:'0',
        padding:'0',display:'grid',placeItems:'center',overflow:'hidden'});
      Object.assign(svg.style,{width:'100%',height:'100%',maxWidth:'100%',maxHeight:'100%'});
      if (rootSvg) { svg.style.width = vw+'px'; svg.style.height = vh+'px'; }
      svg.setAttribute('preserveAspectRatio','xMidYMid meet');
    } else {
      Object.assign(body.style, original);
      if (svg) Object.assign(svg.style, svgOriginal);
      body.style.zoom = '1';
      const naturalWidth = Math.max(body.scrollWidth, root.scrollWidth, vw);
      const scale = manual === null ? Math.min(1, vw / naturalWidth) : manual;
      body.style.zoom = String(scale);
      if (scale < 1) body.style.width = (vw / scale) + 'px';
    }
  }
  function schedule() {
    if (scheduled) return;
    scheduled = true;
    requestAnimationFrame(() => { scheduled = false; fit(); });
  }
  window.__expertPreviewFit = schedule;
  window.__expertPreviewSetZoom = value => {
    manual = typeof value === 'number' && isFinite(value)
      ? Math.max(.25, Math.min(3, value)) : null;
    schedule();
  };
  window.addEventListener('message', event => {
    if (event.source !== parent || !event.data ||
        event.data.type !== 'expert-preview-scale') return;
    window.__expertPreviewSetZoom(event.data.zoom);
  });
  window.addEventListener('resize', schedule);
  window.addEventListener('load', schedule);
  document.addEventListener('DOMContentLoaded', schedule);
  schedule();
})();
''';

String previewSetZoomScript(double? zoom, {bool sandboxed = true}) {
  final value = zoom == null ? 'null' : jsonEncode(zoom.clamp(.25, 3));
  return sandboxed
      ? "document.querySelector('iframe')?.contentWindow.postMessage({type:'expert-preview-scale',zoom:$value},'*');"
      : 'window.__expertPreviewSetZoom?.($value);';
}
