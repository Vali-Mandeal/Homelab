import React, { useEffect, useRef, useState } from 'react';
import BrowserOnly from '@docusaurus/BrowserOnly';
import styles from './Diagram.module.css';

// Shared script loader - only injects the <script> tag once regardless of
// how many <Diagram> components are on the same page.
let _scriptState = 'idle'; // 'idle' | 'loading' | 'ready'
const _waiters = [];

function loadViewer(basePath) {
  return new Promise((resolve) => {
    if (_scriptState === 'ready') { resolve(); return; }
    _waiters.push(resolve);
    if (_scriptState === 'loading') return;

    _scriptState = 'loading';

    // Set globals the viewer reads before initialising
    window.DRAWIO_BASE_URL = basePath;

    const s = document.createElement('script');
    s.src = `${basePath}/vendor/viewer-static.min.js`;
    s.async = false; // load synchronously so GraphViewer is defined on load
    s.onload = () => {
      _scriptState = 'ready';
      _waiters.forEach(r => r());
      _waiters.length = 0;
    };
    s.onerror = () => {
      _scriptState = 'idle'; // allow retry
      _waiters.forEach(r => r()); // still resolve so we show an error
      _waiters.length = 0;
    };
    document.head.appendChild(s);
  });
}

function DiagramInner({ src, caption, height = 480 }) {
  const wrapperRef = useRef(null);
  const [status, setStatus] = useState('loading'); // 'loading' | 'ready' | 'error'
  const [errorMsg, setErrorMsg] = useState('');

  useEffect(() => {
    let cancelled = false;

    async function render() {
      // Derive the base path from window.location (e.g. /dummy)
      const basePath = window.location.pathname.split('/').filter(Boolean)[0]
        ? `/${window.location.pathname.split('/').filter(Boolean)[0]}`
        : '';

      // 1. Fetch the .drawio XML
      let xml;
      try {
        const res = await fetch(src, { cache: 'no-store' });
        if (!res.ok) throw new Error(`HTTP ${res.status} - ${src}`);
        xml = await res.text();
      } catch (e) {
        if (!cancelled) { setErrorMsg(e.message); setStatus('error'); }
        return;
      }

      if (cancelled) return;

      // 2. Load viewer script
      await loadViewer(basePath);

      if (cancelled || !wrapperRef.current) return;

      // 3. Create a fresh target div (avoids double-processing issues)
      wrapperRef.current.innerHTML = '';
      const target = document.createElement('div');
      target.className = 'mxgraph';
      target.setAttribute('data-mxgraph', JSON.stringify({
        xml,
        highlight: '#7c6af5',
        nav: true,
        resize: true,
        toolbar: 'zoom lightbox',
        tooltips: true,
        lightbox: true,
        'auto-fit': true,
      }));
      wrapperRef.current.appendChild(target);

      // 4. Trigger the viewer - it scans for .mxgraph divs
      if (window.GraphViewer) {
        window.GraphViewer.processElements();
        if (!cancelled) setStatus('ready');
      } else {
        if (!cancelled) { setErrorMsg('viewer-static.min.js loaded but GraphViewer not found'); setStatus('error'); }
      }
    }

    render();
    return () => { cancelled = true; };
  }, [src]);

  return (
    <figure className={styles.figure}>
      {status === 'loading' && (
        <div className={styles.placeholder} style={{ height }}>
          <span className={styles.loadingText}>Loading diagram…</span>
        </div>
      )}
      {status === 'error' && (
        <div className={styles.error} style={{ height }}>
          <span>⚠ {errorMsg}</span>
        </div>
      )}
      <div
        ref={wrapperRef}
        className={styles.container}
        style={{
          height: status === 'ready' ? height : 0,
          overflow: 'hidden',
          visibility: status === 'ready' ? 'visible' : 'hidden',
        }}
      />
      {caption && <figcaption className={styles.caption}>{caption}</figcaption>}
    </figure>
  );
}

/**
 * Renders a .drawio diagram using the self-hosted draw.io viewer.
 *
 * Usage in any .md or .mdx file:
 *   <Diagram src="/dummy/diagrams/my-file.drawio" caption="System overview" height={600} />
 *
 * Props:
 *   src      - full path to the .drawio file (include baseUrl prefix, e.g. /dummy/diagrams/...)
 *   caption  - optional caption shown below
 *   height   - container height in px (default 480)
 */
export default function Diagram({ src, caption, height }) {
  return (
    <BrowserOnly fallback={
      <div style={{ height: height ?? 480, background: 'var(--ifm-code-background)', borderRadius: 8, display: 'flex', alignItems: 'center', justifyContent: 'center', color: 'var(--ifm-color-secondary)', fontSize: '0.9rem' }}>
        Loading diagram…
      </div>
    }>
      {() => <DiagramInner src={src} caption={caption} height={height} />}
    </BrowserOnly>
  );
}
