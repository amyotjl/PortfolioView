import { describe, expect, it } from 'vitest'
import { escapeHtml, hexToRgb, mixHex, sampleRamp } from './colors'

describe('escapeHtml', () => {
  it('escapes the HTML-significant characters', () => {
    expect(escapeHtml(`<b>a</b>&"'`)).toBe('&lt;b&gt;a&lt;/b&gt;&amp;&quot;&#39;')
  })

  it('leaves ordinary text untouched', () => {
    expect(escapeHtml('AAPL')).toBe('AAPL')
    expect(escapeHtml('ETF / Fund')).toBe('ETF / Fund')
  })
})

describe('hexToRgb / mixHex', () => {
  it('parses #rrggbb channels', () => {
    expect(hexToRgb('#2f62f5')).toEqual({ r: 47, g: 98, b: 245 })
  })

  it('interpolates linearly, rounding to a byte', () => {
    expect(mixHex('#000000', '#ffffff', 0)).toBe('#000000')
    expect(mixHex('#000000', '#ffffff', 1)).toBe('#ffffff')
    expect(mixHex('#000000', '#ffffff', 0.5)).toBe('#808080')
  })
})

describe('sampleRamp', () => {
  it('returns [] for a non-positive count or empty stops', () => {
    expect(sampleRamp(['#000000', '#ffffff'], 0)).toEqual([])
    expect(sampleRamp([], 3)).toEqual([])
  })

  it('returns the first (darkest) stop for a single slice', () => {
    expect(sampleRamp(['#000000', '#ffffff'], 1)).toEqual(['#000000'])
  })

  it('spans the ramp endpoints and interpolates the middle', () => {
    expect(sampleRamp(['#000000', '#ffffff'], 3)).toEqual(['#000000', '#808080', '#ffffff'])
  })

  it('supports more slices than stops (10+ allocation slices)', () => {
    const stops = ['#184f95', '#256abf', '#2a78d6', '#3987e5', '#5598e7', '#6da7ec', '#86b6ef']
    const colors = sampleRamp(stops, 12)
    expect(colors).toHaveLength(12)
    expect(colors[0]).toBe(stops[0]) // largest = darkest
    expect(colors[11]).toBe(stops[stops.length - 1]) // smallest = lightest
    expect(new Set(colors).size).toBeGreaterThan(1)
  })
})
