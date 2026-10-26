// Build the store plugin (UI embedded) and the release assets.
// node plugin/build-plugin.js <renderer-binary> <out-dir>
// Versions and the GitHub repo come from version.config.json at the repo root.
const fs = require('fs')
const path = require('path')
const zlib = require('zlib')
const crypto = require('crypto')

const ROOT = path.join(__dirname, '..')
const [binPath, outDir] = process.argv.slice(2)
if (!binPath || !outDir) throw new Error('usage: build-plugin.js <renderer-binary> <out-dir>')
const cfg = JSON.parse(fs.readFileSync(path.join(ROOT, 'version.config.json'), 'utf8'))
const uiDir = path.join(ROOT, 'ui')
const MTIME = Number(process.env.SOURCE_DATE_EPOCH) || 0

const walk = (dir, rel = '') => fs.readdirSync(dir, { withFileTypes: true }).flatMap((e) => {
  if (e.name.startsWith('.')) return []
  const r = rel ? `${rel}/${e.name}` : e.name
  return e.isDirectory() ? walk(path.join(dir, e.name), r) : [r]
})

const files = {}
for (const rel of walk(uiDir).sort()) {
  const text = fs.readFileSync(path.join(uiDir, rel), 'utf8').replace(/\r\n?/g, '\n')
  if (/[^\x09\x0a\x20-\x7e -￿]/.test(text.replace(/[\ud800-\udfff]/g, ''))) throw new Error(`unexpected control chars in ${rel}`)
  files[rel] = text
}
files['.ui-version'] = `${cfg.ui}\n`
const managed = Object.keys(files).sort()
files['.devui-managed-files'] = managed.join('\n') + '\n'

// ---- plugin txt ----
const literal = JSON.stringify(files, null, 1)
  .replace(/</g, '\\u003c')
  .split(String.fromCharCode(0x2028)).join('\\u2028')
  .split(String.fromCharCode(0x2029)).join('\\u2029')
const src = fs.readFileSync(path.join(__dirname, 'plugin.src.html'), 'utf8').replace(/\r\n?/g, '\n')
for (const p of ['__UI_FILES__', "'__UI_VERSION__'", "'__PLUGIN_VERSION__'", "'__REPO__'"]) if (!src.includes(p)) throw new Error(`placeholder missing: ${p}`)
const plugin = src
  .replace(/__PLUGIN_VERSION__/g, cfg.plugin)
  .replace(/__REPO__/g, cfg.repo)
  .replace("'__UI_VERSION__'", JSON.stringify(cfg.ui))
  .replace('__UI_FILES__', () => literal)
fs.mkdirSync(outDir, { recursive: true })
const pluginName = `u60pro-screen-plugin-v${cfg.plugin}.txt`
fs.writeFileSync(path.join(outDir, pluginName), plugin)

// ---- ui.tar.gz (ustar, deterministic; BusyBox tar can unpack it) ----
const enc = new TextEncoder()
const header = (name, size, mode, type) => {
  const h = Buffer.alloc(512)
  const put = (s, off, len) => Buffer.from(enc.encode(s)).copy(h, off, 0, len)
  const oct = (n, len) => n.toString(8).padStart(len - 1, '0') + '\0'
  put(name, 0, 100); put(oct(mode, 8), 100, 8); put(oct(0, 8), 108, 8); put(oct(0, 8), 116, 8)
  put(oct(size, 12), 124, 12); put(oct(MTIME, 12), 136, 12)
  h.fill(32, 148, 156); put(type, 156, 1); put('ustar\0', 257, 6); put('00', 263, 2)
  let sum = 0
  for (const b of h) sum += b
  put(sum.toString(8).padStart(6, '0') + '\0 ', 148, 8)
  return h
}
const chunks = []
const dirs = [...new Set(Object.keys(files).filter((p) => p.includes('/')).map((p) => p.slice(0, p.lastIndexOf('/') + 1)))].sort()
dirs.forEach((d) => chunks.push(header(d, 0, 0o755, '5')))
for (const p of Object.keys(files).sort()) {
  if (enc.encode(p).length >= 100) throw new Error(`path too long: ${p}`)
  const data = Buffer.from(files[p], 'utf8')
  chunks.push(header(p, data.length, p.endsWith('.sh') ? 0o755 : 0o644, '0'), data)
  const pad = (512 - (data.length % 512)) % 512
  if (pad) chunks.push(Buffer.alloc(pad))
}
chunks.push(Buffer.alloc(1024))
fs.writeFileSync(path.join(outDir, 'ui.tar.gz'), zlib.gzipSync(Buffer.concat(chunks), { level: 9 }))

// ---- renderer + checksums + version.json ----
const bin = fs.readFileSync(binPath)
if (bin.slice(0, 4).toString('latin1') !== '\x7fELF' || bin[4] !== 2 || bin.readUInt16LE(18) !== 0xb7) throw new Error('renderer is not an AArch64 ELF')
if (!bin.includes(Buffer.from('DEVUI-XPAGE-API-2'))) throw new Error('renderer lacks the xpage API 2 marker')
fs.writeFileSync(path.join(outDir, 'u60pro-devui-aarch64'), bin)
const sha = (n) => crypto.createHash('sha256').update(fs.readFileSync(path.join(outDir, n))).digest('hex')
const assets = ['u60pro-devui-aarch64', 'ui.tar.gz', pluginName]
fs.writeFileSync(path.join(outDir, 'SHA256SUMS'), assets.map((n) => `${sha(n)}  ${n}`).join('\n') + '\n')
fs.writeFileSync(path.join(outDir, 'version.json'), JSON.stringify({
  schema: 2,
  tag: `v${cfg.plugin}`,
  repo: cfg.repo,
  plugin: { version: cfg.plugin, asset: pluginName, sha256: sha(pluginName) },
  devui: { version: cfg.devui, asset: 'u60pro-devui-aarch64', sha256: sha('u60pro-devui-aarch64'), size: bin.length, notes: cfg.devuiNotes },
  ui: { version: cfg.ui, asset: 'ui.tar.gz', sha256: sha('ui.tar.gz'), notes: cfg.uiNotes },
}, null, 2) + '\n')
console.log(`plugin ${(plugin.length / 1024).toFixed(1)} KB, ${managed.length} UI files`)
console.log(fs.readFileSync(path.join(outDir, 'SHA256SUMS'), 'utf8'))
