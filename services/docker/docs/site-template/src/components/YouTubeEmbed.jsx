import React from 'react';
import styles from './YouTubeEmbed.module.css';

/**
 * Embeds a YouTube video with a responsive 16:9 wrapper.
 *
 * Usage in MDX:
 *   import YouTubeEmbed from '@site/src/components/YouTubeEmbed';
 *   <YouTubeEmbed id="dQw4w9WgXcQ" title="My Video" />
 */
export default function YouTubeEmbed({ id, title, caption }) {
  return (
    <figure className={styles.figure}>
      <div className={styles.wrapper}>
        <iframe
          className={styles.iframe}
          src={`https://www.youtube-nocookie.com/embed/${id}`}
          title={title || 'YouTube video'}
          frameBorder="0"
          allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share"
          allowFullScreen
        />
      </div>
      {caption && <figcaption className={styles.caption}>{caption}</figcaption>}
    </figure>
  );
}
