// Regression tests for the BUILT bundle (Gital/Resources/ShikiDiff.js),
// driven against a linkedom DOM shaped like DiffHTMLBuilder output.
// build.sh runs this after every bundle; it exits non-zero on failure.
import { readFileSync } from 'node:fs'
import { parseHTML } from 'linkedom'

const bundle = readFileSync(new URL('../../Gital/Resources/ShikiDiff.js', import.meta.url), 'utf8')

const line = (kind, text) =>
  `<div class="line ${kind}"><span class="num"></span><span class="num"></span><span class="sign"></span><span class="text">${text}</span></div>`

// Painting is deferred one task per group; a few macrotask turns flushes it.
const settle = () => new Promise((resolve) => setTimeout(resolve, 50))

async function render(body) {
  const { window, document } = parseHTML(`<!DOCTYPE html><html><head></head><body data-lang="swift">${body}</body></html>`)
  globalThis.document = document
  globalThis.window = window
  new Function(bundle)()
  await settle()
  return document
}

const failures = []
const check = (name, condition) => {
  if (!condition) { failures.push(name) }
  console.log(`${condition ? 'ok' : 'FAIL'} - ${name}`)
}

// 1. Cross-hunk-line constructs color, and painting preserves textContent.
{
  const doc = await render(
    '<div class="hunk"></div>'
    + line('ctx', '/* start of a')
    + line('del', '   comment */ let removed = "gone"')
    + line('add', '   comment */ let added = 42')
  )
  const texts = [...doc.querySelectorAll('.text')]
  check('multi-line comment colors across rows',
    doc.querySelector('.text span[style]')?.textContent === '/* start of a')
  check('textContent preserved after painting',
    texts.map((el) => el.textContent).join('|') === '/* start of a|   comment */ let removed = "gone"|   comment */ let added = 42')
  check('dark-mode flip style injected', !!doc.querySelector('style'))
}

// 2. CRLF: the parser-normalized trailing \n is stripped for tokenization
// and restored after painting, so CRLF files highlight instead of bailing.
{
  const doc = await render('<div class="hunk"></div>' + line('ctx', 'let a = 1\n') + line('add', 'let b = 2\n'))
  const texts = [...doc.querySelectorAll('.text')]
  check('CRLF rows still get colored spans', doc.querySelectorAll('.text span[style]').length > 0)
  check('CRLF rows keep their trailing newline', texts.every((el) => el.textContent.endsWith('\n')))
}

// 3. Oversized groups (generated files) are skipped, not frozen over —
// whether the size comes from many rows or one enormous minified line.
{
  const big = Array.from({ length: 1001 }, (_, i) => line('ctx', `let v${i} = ${i}`)).join('')
  const doc = await render('<div class="hunk"></div>' + big)
  check('over-row-cap group stays unpainted', doc.querySelectorAll('.text span').length === 0)

  const minified = line('add', `let x = "${'a'.repeat(200001)}"`)
  const doc2 = await render('<div class="hunk"></div>' + minified)
  check('over-char-cap group stays unpainted', doc2.querySelectorAll('.text span').length === 0)
}

// 4. Split: sides tokenize independently, filler sides stay untouched.
{
  const doc = await render(`
    <div class="hunk"></div>
    <div class="row"><div class="side left del"><span class="text">let old = 1</span></div><div class="side right add"><span class="text">let new1 = 2</span></div></div>
    <div class="row"><div class="side left "><span class="text"></span></div><div class="side right add"><span class="text">let extra = 3</span></div></div>
  `)
  check('split del side colored', doc.querySelectorAll('.side.del .text span[style]').length > 0)
  check('split add side colored', doc.querySelectorAll('.side.add .text span[style]').length > 0)
  check('split filler side untouched', doc.querySelector('.side.left:not(.del):not(.ctx) .text').childNodes.length === 0)
}

// 5. Multi-file page: each section.file[data-lang] tokenizes with its own
// grammar; a section without data-lang (unknown language) stays uncolored,
// and spacer divs between rows don't break grouping.
{
  const { window, document } = parseHTML(`<!DOCTYPE html><html><head></head><body>
    <section class="file" data-lang="swift"><div class="sp"></div><div class="hunk"></div>${line('add', 'let a = 1')}<div class="sp"></div>${line('add', 'let b = 2')}</section>
    <section class="file" data-lang="python"><div class="hunk"></div>${line('add', 'def f(): pass')}</section>
    <section class="file"><div class="hunk"></div>${line('add', 'let plain = 1')}</section>
  </body></html>`)
  globalThis.document = document
  globalThis.window = window
  new Function(bundle)()
  await settle()
  const sections = [...document.querySelectorAll('section.file')]
  check('multi-file: swift section colored', sections[0].querySelectorAll('.text span[style]').length > 0)
  check('multi-file: spacer-separated row still colored', sections[0].querySelectorAll('.line:last-of-type .text span[style]').length > 0)
  check('multi-file: python section colored', sections[1].querySelectorAll('.text span[style]').length > 0)
  check('multi-file: untagged section untouched', sections[2].querySelectorAll('.text span').length === 0)
}

if (failures.length) {
  console.error(`\n${failures.length} bundle test(s) failed`)
  process.exit(1)
}
console.log('\nall bundle tests passed')
