import React from 'react';
import MDXComponents from '@theme-original/MDXComponents';
import YouTubeEmbed from '@site/src/components/YouTubeEmbed';
import DownloadSection from '@site/src/components/DownloadSection';
import Diagram from '@site/src/components/Diagram';

// Register components globally - no per-page imports needed.
// Usage in any .md or .mdx file:
//   <YouTubeEmbed id="VIDEO_ID" title="Title" caption="Optional caption" />
//   <DownloadSection title="Resources" files={[{ name: "...", url: "/...", description: "...", size: "..." }]} />
//   <Diagram src="/diagrams/my-file.drawio" caption="Optional caption" height={500} />
export default {
  ...MDXComponents,
  YouTubeEmbed,
  DownloadSection,
  Diagram,
};
