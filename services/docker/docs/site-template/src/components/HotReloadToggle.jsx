import React, { useState, useEffect, useRef } from 'react';

const STORAGE_KEY = 'docHotReloadMode';

export default function HotReloadToggle() {
  const [active, setActive] = useState(false);
  const intervalRef = useRef(null);
  const lastEtagRef = useRef(null);

  useEffect(() => {
    setActive(localStorage.getItem(STORAGE_KEY) === 'true');
  }, []);

  useEffect(() => {
    if (active) {
      lastEtagRef.current = null;

      intervalRef.current = setInterval(async () => {
        try {
          // HEAD on the JS bundle - tiny request, no body transferred
          const res = await fetch(
            `${window.location.origin}${window.location.pathname.replace(/\/$/, '').split('/').slice(0, 2).join('/')}/runtime~main.js`,
            { method: 'HEAD', cache: 'no-store' }
          );
          const etag = res.headers.get('etag');
          if (lastEtagRef.current !== null && lastEtagRef.current !== etag) {
            window.location.reload();
          }
          lastEtagRef.current = etag;
        } catch { /* ignore */ }
      }, 1000);
    } else {
      clearInterval(intervalRef.current);
      intervalRef.current = null;
      lastEtagRef.current = null;
    }
    return () => clearInterval(intervalRef.current);
  }, [active]);

  const toggle = () => {
    setActive(prev => {
      const next = !prev;
      localStorage.setItem(STORAGE_KEY, String(next));
      return next;
    });
  };

  return (
    <button
      onClick={toggle}
      title={active ? 'Hot reload: ON - reloads when content changes (click to disable)' : 'Hot reload mode - auto-reload on file changes (click to enable)'}
      aria-label="Toggle hot reload mode"
      style={{
        background: active ? 'var(--ifm-color-primary)' : 'none',
        border: '1px solid var(--ifm-color-primary)',
        borderRadius: '6px',
        cursor: 'pointer',
        padding: '4px 8px',
        fontSize: '13px',
        lineHeight: 1,
        color: active ? '#fff' : 'var(--ifm-color-primary)',
        transition: 'background 0.2s, color 0.2s',
        display: 'flex',
        alignItems: 'center',
        gap: '4px',
        fontFamily: 'monospace',
      }}
    >
      ⚡{active ? ' LIVE' : ''}
    </button>
  );
}
