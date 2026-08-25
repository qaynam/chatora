import { describe, expect, test } from 'bun:test'
import { imageSizeOf } from './imageSize'

// Real encoder output (ImageMagick), inlined so the parser is checked against bytes a
// real host would serve rather than against hand-written headers.
const FIXTURES: readonly {
  readonly name: string
  readonly base64: string
  readonly width: number
  readonly height: number
}[] = [
  {
    name: 'PNG',
    width: 123,
    height: 45,
    base64:
      'iVBORw0KGgoAAAANSUhEUgAAAHsAAAAtAQMAAAC03obWAAAAIGNIUk0AAHomAACAhAAA+gAAAIDo' +
      'AAB1MAAA6mAAADqYAAAXcJy6UTwAAAAGUExURf8AAP///0EdNBEAAAABYktHRAH/Ai3eAAAAB3RJ' +
      'TUUH6ggZASYwgq8YLwAAACV0RVh0ZGF0ZTpjcmVhdGUAMjAyNi0wOC0yNVQwMTozODo0OCswMDow' +
      'MDmv08sAAAAldEVYdGRhdGU6bW9kaWZ5ADIwMjYtMDgtMjVUMDE6Mzg6NDgrMDA6MDBI8mt3AAAA' +
      'KHRFWHRkYXRlOnRpbWVzdGFtcAAyMDI2LTA4LTI1VDAxOjM4OjQ4KzAwOjAwH+dKqAAAAA9JREFU' +
      'KM9jYBgFo2CEAgAC/QAB2Mo24AAAAABJRU5ErkJggg==',
  },
  {
    name: 'baseline JPEG',
    width: 200,
    height: 77,
    base64:
      '/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAMCAgICAgMCAgIDAwMDBAYEBAQEBAgGBgUGCQgKCgkI' +
      'CQkKDA8MCgsOCwkJDRENDg8QEBEQCgwSExIQEw8QEBD/2wBDAQMDAwQDBAgEBAgQCwkLEBAQEBAQ' +
      'EBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBD/wAARCABNAMgDAREA' +
      'AhEBAxEB/8QAFQABAQAAAAAAAAAAAAAAAAAAAAn/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/8QAFgEB' +
      'AQEAAAAAAAAAAAAAAAAAAAYJ/8QAFBEBAAAAAAAAAAAAAAAAAAAAAP/aAAwDAQACEQMRAD8Anu1T' +
      'Q4AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' +
      'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' +
      'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' +
      'AAAAAAAAAAAAAAAAAAAAAAD/2Q==',
  },
  {
    name: 'GIF',
    width: 64,
    height: 32,
    base64:
      'R0lGODlhQAAgAPAAAACAAAAAACH5BAAAAAAALAAAAABAACAAAAIthI+py+0Po5y02ouz3rz7D4bi' +
      'SJbmiabqyrbuC8fyTNf2jef6zvf+DwwKh6QCADs=',
  },
  {
    name: 'lossy WebP (VP8)',
    width: 150,
    height: 99,
    base64:
      'UklGRmgAAABXRUJQVlA4IFwAAADQBgCdASqWAGMAPpFIoUylpCMiIIgAsBIJaW7hdUAAT22IvEFR' +
      'z2xF4gqOe2IvEFRz2xF4gqOe2IvEFRz2tAAA/v8jU///unr//aev/9p6/mD/8jnelRgAAAAAAA==',
  },
  {
    name: 'lossless WebP (VP8L)',
    width: 300,
    height: 120,
    base64: 'UklGRiQAAABXRUJQVlA4TBcAAAAvK8EdAAcQ/Y/+B4QECf/fm4zof9r/ngA=',
  },
  {
    name: 'JPEG with an EXIF segment before the frame',
    width: 90,
    height: 180,
    base64:
      '/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAMCAgMCAgMDAwMEAwMEBQgFBQQEBQoHBwYIDAoMDAsK' +
      'CwsNDhIQDQ4RDgsLEBYQERMUFRUVDA8XGBYUGBIUFRT/2wBDAQMEBAUEBQkFBQkUDQsNFBQUFBQU' +
      'FBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBT/wAARCAC0AFoDAREA' +
      'AhEBAxEB/8QAFgABAQEAAAAAAAAAAAAAAAAAAAMI/8QAGRABAQEBAQEAAAAAAAAAAAAAABJxYQER' +
      '/8QAGAEBAQADAAAAAAAAAAAAAAAAAAUEBwn/xAAYEQEBAQEBAAAAAAAAAAAAAAAAEwESEf/aAAwD' +
      'AQACEQMRAD8AznTS0nUyhRIoUSKFEihRIoUSKFEihRIoUSKFEihRIoUSKI1inNNoVhMoVhMoVhMo' +
      'VhMoVhMoVhMoVhMoVhMoVhMoVhMoVhMojXVWSdQrpIoV0kUK6SKFdJFCukihXSRQrpIoV0kUK6SK' +
      'FdJFCukiiV9VJp1C+kyhfSZQvpMoX0mUL6TKF9JlC+kyhfSZQvpMoX0mUL6TKI2qTTaFkyhZMoWT' +
      'KFkyhZMoWTKFkyhZMoWTKFkyhZMolarJNoWSKFkihZIoWSKFkihZIoWSKFkihZIoWSKFkiiNaqTT' +
      'aFaTKFaTKFaTKFaTKFaTKFaTKFaTKFaTKFaTKFaTKFaTKI0qSTaFEihRIoUSKFEihRIoUSKFEihR' +
      'IoUSKFEihRIolSrJOoUSKFEihRIoUSKFEihRIoUSKFEihRIoUSKFEiiNYqzTaFYTKFYTKFYTKFYT' +
      'KFYTKFYTKFYTKFYTKFYTKFYTKFYTKI2pyTaFkihZIoWSKFkihZIoWSKFkihZIoWSKFkihZIolarN' +
      'OoWTKFkyhZMoWTKFkyhZMoWTKFkyhZMoWTKFkyiN9VJptC+kyhfSZQvpMoX0mUL6TKF9JlC+kyhf' +
      'SZQvpMoX0mUL6TKI11Vkm0K6SKFdJFCukihXSRQrpIoV0kUK6SKFdJFCukihXSRQrpIolWqk07sr' +
      'SZ2VpM7K0mdlaTOytJnZWkzsrSZ2VpM7K0mdlaTOytJnaNKkk2hRIoUSKFEihRIoUSKFEihRIoUS' +
      'KFEihRIoUSKJUqTTqFEyhRMoUTKFEyhRMoUTKFEyhRMoUTKFEyhRMojSpNNoUTKFEyhRMoUTKFEy' +
      'hRMoUTKFEyhRMoUTKFEyiNKsk2hRIoUSKFEihRIoUSKFEihRIoUSKFEihRIoUSKJVipNNoVhMoVh' +
      'MoVhMoVhMoVhMoVhMoVhMoVhMoVhMoVhMoVhMojWKkk6hWEihWEihWEihWEihWEihWEihWEihWEi' +
      'hWEihWEihWEiiN9VZptC+kyhfSZQvpMoX0mUL6TKF9JlC+kyhfSZQvpMoX0mUL6TKJ/fVDzGB1p9' +
      '9PMOtPvp5h1p99PMOtPvp5h1p99PMOtPvp5h1p99PMOtPvp5h1p99PMOtPvp5h1p99PMOtf/2Q==',
  },
]

describe('imageSizeOf', () => {
  test.each(FIXTURES.map((f) => [f.name, f] as const))('reads %s', (_name, fixture) => {
    const bytes = Uint8Array.from(atob(fixture.base64), (c) => c.charCodeAt(0))
    expect(imageSizeOf(bytes)).toEqual({ width: fixture.width, height: fixture.height })
  })

  test('an unknown format has no size', () => {
    expect(imageSizeOf(new Uint8Array([1, 2, 3, 4, 5, 6, 7, 8]))).toBeUndefined()
  })

  test('a truncated PNG header has no size', () => {
    expect(
      imageSizeOf(new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0])),
    ).toBeUndefined()
  })

  test('a zero-dimension image is treated as unmeasurable', () => {
    const png = new Uint8Array(24)
    png.set([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
    expect(imageSizeOf(png)).toBeUndefined()
  })
})
