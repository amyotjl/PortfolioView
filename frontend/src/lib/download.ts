/**
 * Save a Blob to the user's disk (portfolio export, issue #64).
 *
 * Kept in its own module because it is the one genuinely DOM-imperative step in
 * the export flow: everything upstream is a normal typed fetch, and isolating the
 * anchor/objectURL dance here keeps the composable testable.
 */

/** Same-tab download via a synthetic anchor click. */
export function saveBlob(blob: Blob, filename: string): void {
  // jsdom (and any non-browser host) has no createObjectURL; bail rather than
  // throwing so a unit test importing this module doesn't need a DOM shim.
  if (typeof URL.createObjectURL !== 'function') return

  const url = URL.createObjectURL(blob)
  try {
    const anchor = document.createElement('a')
    anchor.href = url
    anchor.download = filename
    // Firefox requires the anchor to be in the document for a programmatic click.
    anchor.style.display = 'none'
    document.body.appendChild(anchor)
    anchor.click()
    anchor.remove()
  } finally {
    // Revoking synchronously is safe: the click has already handed the blob to
    // the download manager. Not revoking leaks the whole file for the tab's life.
    URL.revokeObjectURL(url)
  }
}
