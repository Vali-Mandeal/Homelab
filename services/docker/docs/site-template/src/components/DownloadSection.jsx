import React from 'react';
import styles from './DownloadSection.module.css';

const icons = {
  pdf:  '📄',
  zip:  '📦',
  cs:   '🔷',
  code: '💻',
  json: '📋',
  md:   '📝',
  default: '⬇️',
};

function getIcon(filename) {
  if (!filename) return icons.default;
  const ext = filename.split('.').pop().toLowerCase();
  return icons[ext] || icons.default;
}

/**
 * A styled download area for files.
 *
 * Usage in MDX:
 *   import DownloadSection from '@site/src/components/DownloadSection';
 *
 *   <DownloadSection
 *     title="Source Code & Resources"
 *     files={[
 *       { name: "BenchmarkExamples.cs", url: "/files/BenchmarkExamples.cs", description: "All benchmark code from this chapter", size: "12 KB" },
 *       { name: "slides.pdf", url: "/files/slides.pdf", description: "Presentation slides", size: "2.4 MB" },
 *     ]}
 *   />
 */
export default function DownloadSection({ title, files = [] }) {
  return (
    <div className={styles.container}>
      {title && <h3 className={styles.title}>{title}</h3>}
      <div className={styles.grid}>
        {files.map((file, i) => (
          <a
            key={i}
            href={file.url}
            download={file.url && file.url !== '#' ? file.name : undefined}
            target={file.external ? '_blank' : undefined}
            rel={file.external ? 'noopener noreferrer' : undefined}
            className={styles.card}
          >
            <span className={styles.icon}>{file.icon || getIcon(file.name)}</span>
            <div className={styles.info}>
              <span className={styles.name}>{file.name}</span>
              {file.description && (
                <span className={styles.description}>{file.description}</span>
              )}
              {file.size && <span className={styles.size}>{file.size}</span>}
            </div>
            <span className={styles.arrow}>↓</span>
          </a>
        ))}
      </div>
    </div>
  );
}
