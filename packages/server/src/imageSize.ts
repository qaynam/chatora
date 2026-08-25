export interface ImageSize {
  readonly width: number
  readonly height: number
}

const startsWith = (bytes: Uint8Array, signature: readonly number[], offset = 0): boolean =>
  signature.every((byte, i) => bytes[offset + i] === byte)

const PNG_SIGNATURE = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]

const pngSize = (view: DataView): ImageSize | undefined =>
  view.byteLength >= 24 ? { width: view.getUint32(16), height: view.getUint32(20) } : undefined

const gifSize = (view: DataView): ImageSize | undefined =>
  view.byteLength >= 10
    ? { width: view.getUint16(6, true), height: view.getUint16(8, true) }
    : undefined

// Frame markers carrying dimensions. 0xC4/0xC8/0xCC share the SOFn range but are
// Huffman/arithmetic tables, not frames.
const SOF_MARKERS = new Set([
  0xc0, 0xc1, 0xc2, 0xc3, 0xc5, 0xc6, 0xc7, 0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf,
])

/** Walks the segment chain to the first frame header; entropy-coded data is never reached. */
const jpegSize = (bytes: Uint8Array, view: DataView): ImageSize | undefined => {
  let offset = 2
  while (offset + 9 < bytes.length) {
    if (bytes[offset] !== 0xff) {
      offset++
      continue
    }
    const marker = bytes[offset + 1] as number
    // Standalone markers carry no length field.
    if (marker === 0xd8 || marker === 0x01 || (marker >= 0xd0 && marker <= 0xd7)) {
      offset += 2
      continue
    }
    if (SOF_MARKERS.has(marker)) {
      return { height: view.getUint16(offset + 5), width: view.getUint16(offset + 7) }
    }
    offset += 2 + view.getUint16(offset + 2)
  }
  return undefined
}

/** VP8 (lossy), VP8L (lossless) and VP8X (extended) each store the size differently. */
const webpSize = (bytes: Uint8Array, view: DataView): ImageSize | undefined => {
  if (bytes.length < 30) return undefined
  const chunk = String.fromCharCode(...bytes.slice(12, 16))
  if (chunk === 'VP8 ') {
    return { width: view.getUint16(26, true) & 0x3fff, height: view.getUint16(28, true) & 0x3fff }
  }
  if (chunk === 'VP8L') {
    const bits = view.getUint32(21, true)
    return { width: (bits & 0x3fff) + 1, height: ((bits >> 14) & 0x3fff) + 1 }
  }
  if (chunk === 'VP8X') {
    const read24 = (at: number) =>
      (bytes[at] as number) | ((bytes[at + 1] as number) << 8) | ((bytes[at + 2] as number) << 16)
    return { width: read24(24) + 1, height: read24(27) + 1 }
  }
  return undefined
}

/**
 * Intrinsic pixel dimensions read from the image's own header — PNG, GIF, JPEG and WebP.
 * Undefined for anything else and for a truncated file, which the caller answers with a
 * fixed size rather than a computed one.
 *
 * The web client asks the browser (or, for Gyazo, `/api/oembed-proxy/gyazo`); chatora
 * already has the bytes on disk, so reading them needs no request and no ImageMagick.
 * SVG never reaches here: it is rasterized to PNG first.
 */
export const imageSizeOf = (bytes: Uint8Array): ImageSize | undefined => {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength)
  let size: ImageSize | undefined
  if (startsWith(bytes, PNG_SIGNATURE)) size = pngSize(view)
  else if (startsWith(bytes, [0x47, 0x49, 0x46, 0x38])) size = gifSize(view)
  else if (startsWith(bytes, [0xff, 0xd8])) size = jpegSize(bytes, view)
  else if (
    startsWith(bytes, [0x52, 0x49, 0x46, 0x46]) &&
    startsWith(bytes, [0x57, 0x45, 0x42, 0x50], 8)
  )
    size = webpSize(bytes, view)
  return size && size.width > 0 && size.height > 0 ? size : undefined
}
