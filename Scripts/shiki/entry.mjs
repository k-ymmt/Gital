// Entry point for the Shiki syntax-highlighting bundle injected into every
// diff page as a WKUserScript (see DiffSyntaxHighlighting.swift). Build with
// ./build.sh — the output (Gital/Resources/ShikiDiff.js) is committed so the
// app builds without a Node toolchain.
//
// The page (DiffHTMLBuilder) renders plain escaped text and tags <body> with
// data-lang when the file's language is known. This script reconstructs the
// old and new text per hunk from the DOM, tokenizes each side once (so
// multi-line constructs like block comments highlight correctly), and paints
// the tokens back into each row's .text span. Painting preserves textContent
// exactly, so copy output is unchanged.

import { createHighlighterCoreSync } from '@shikijs/core'
import { createJavaScriptRegexEngine } from '@shikijs/engine-javascript'
import githubLight from '@shikijs/themes/github-light'
import githubDark from '@shikijs/themes/github-dark'

import c from '@shikijs/langs/c'
import cpp from '@shikijs/langs/cpp'
import csharp from '@shikijs/langs/csharp'
import css from '@shikijs/langs/css'
import dart from '@shikijs/langs/dart'
import diff from '@shikijs/langs/diff'
import docker from '@shikijs/langs/docker'
import go from '@shikijs/langs/go'
import graphql from '@shikijs/langs/graphql'
import groovy from '@shikijs/langs/groovy'
import html from '@shikijs/langs/html'
import java from '@shikijs/langs/java'
import javascript from '@shikijs/langs/javascript'
import json from '@shikijs/langs/json'
import jsx from '@shikijs/langs/jsx'
import kotlin from '@shikijs/langs/kotlin'
import lua from '@shikijs/langs/lua'
import make from '@shikijs/langs/make'
import markdown from '@shikijs/langs/markdown'
import objectiveC from '@shikijs/langs/objective-c'
import perl from '@shikijs/langs/perl'
import php from '@shikijs/langs/php'
import python from '@shikijs/langs/python'
import ruby from '@shikijs/langs/ruby'
import rust from '@shikijs/langs/rust'
import scss from '@shikijs/langs/scss'
import shellscript from '@shikijs/langs/shellscript'
import sql from '@shikijs/langs/sql'
import swift from '@shikijs/langs/swift'
import toml from '@shikijs/langs/toml'
import tsx from '@shikijs/langs/tsx'
import typescript from '@shikijs/langs/typescript'
import vue from '@shikijs/langs/vue'
import xml from '@shikijs/langs/xml'
import yaml from '@shikijs/langs/yaml'
import ini from '@shikijs/langs/ini'

// Keys are the ids DiffSyntaxHighlighting.language(forPath:) emits.
const LANGS = {
  c, cpp, csharp, css, dart, diff, docker, go, graphql, groovy, html, ini,
  java, javascript, json, jsx, kotlin, lua, make, markdown,
  'objective-c': objectiveC, perl, php, python, ruby, rust, scss, shellscript,
  sql, swift, toml, tsx, typescript, vue, xml, yaml,
}

const THEMES = { light: 'github-light', dark: 'github-dark' }

// Oversized groups stay uncolored: tokenization is synchronous, and both a
// multi-thousand-line group (generated/vendored files) and a single enormous
// minified line (a 1MB bundle diff is two rows but megabytes of regex input)
// would burn the shared WebContent process for seconds. Hand-written hunks
// sit far below both caps.
const MAX_GROUP_LINES = 1000
const MAX_GROUP_CHARS = 200000

function tokenize(highlighter, lang, lines) {
  if (!lines.length || lines.length > MAX_GROUP_LINES) { return null }
  let chars = 0
  for (const line of lines) { chars += line.length }
  if (chars > MAX_GROUP_CHARS) { return null }
  let tokens
  try {
    ;({ tokens } = highlighter.codeToTokens(lines.join('\n'), {
      lang,
      themes: THEMES,
      defaultColor: 'light',
    }))
  } catch {
    return null
  }
  // Any mismatch means painting would smear colors across the wrong rows.
  return tokens.length === lines.length ? tokens : null
}

function styleText(token) {
  const style = token.htmlStyle
  if (typeof style === 'string') { return style }
  if (style) {
    return Object.entries(style).map(([key, value]) => `${key}:${value}`).join(';')
  }
  return token.color ? `color:${token.color}` : ''
}

// Colors only — a fontStyle (italic/bold) could change glyph widths and
// therefore wrap points, invalidating the chunk-height cache.
function paint(textEl, tokens) {
  if (!textEl || !tokens || !tokens.length) { return }
  const frag = document.createDocumentFragment()
  for (const token of tokens) {
    const css = styleText(token)
    if (css) {
      const span = document.createElement('span')
      span.style.cssText = css
      span.textContent = token.content
      frag.appendChild(span)
    } else {
      frag.appendChild(document.createTextNode(token.content))
    }
  }
  // Tokens carry the CR-stripped text (see stripped()); restore the
  // normalized \n so textContent — and therefore copies — stay unchanged.
  if (textEl.textContent.endsWith('\n')) {
    frag.appendChild(document.createTextNode('\n'))
  }
  textEl.replaceChildren(frag)
}

// Rows between hunk headers form one tokenization group. Interactive pages
// are chunks that can start mid-hunk (rows before any header), so a leading
// headerless group is expected. `root` is one language scope: <body> on
// single-file pages, a <section class="file"> on multi-file pages — spacer
// divs and other non-row children just fall through the matcher.
function groups(root, matcher) {
  const out = []
  let current = []
  for (const el of root.children) {
    if (el.classList.contains('hunk')) {
      if (current.length) { out.push(current) }
      current = []
    } else if (matcher(el)) {
      current.push(el)
    }
  }
  if (current.length) { out.push(current) }
  return out
}

// CRLF diffs keep each line's trailing \r, which the HTML parser normalized
// to \n inside .text. Strip it before tokenizing — Shiki would split it into
// an extra line and fail the count guard, unpainting the whole group —
// and paint() re-appends it. A \n anywhere else (lone CR mid-line) still
// fails the guard, which degrades to no color, never to smeared rows.
const stripped = (span) => {
  const text = span?.textContent ?? ''
  return text.endsWith('\n') ? text.slice(0, -1) : text
}
const textOf = (el) => stripped(el.querySelector('.text'))
const hasKind = (el) => el.classList.contains('add') || el.classList.contains('del') || el.classList.contains('ctx')

// Unified rows: deletions + context reconstruct the old text, additions +
// context the new; context lines paint from the new side.
function paintUnified(highlighter, lang, lines) {
  const oldLines = []
  const newLines = []
  for (const el of lines) {
    if (!el.classList.contains('add')) { oldLines.push(textOf(el)) }
    if (!el.classList.contains('del')) { newLines.push(textOf(el)) }
  }
  const oldTokens = tokenize(highlighter, lang, oldLines)
  const newTokens = tokenize(highlighter, lang, newLines)
  let oi = 0
  let ni = 0
  for (const el of lines) {
    const textEl = el.querySelector('.text')
    if (el.classList.contains('add')) {
      paint(textEl, newTokens?.[ni++])
    } else if (el.classList.contains('del')) {
      paint(textEl, oldTokens?.[oi++])
    } else {
      paint(textEl, newTokens?.[ni++])
      oi++
    }
  }
}

// Split rows: the left column is the old file, the right the new. Sides
// without a kind class are the empty filler opposite an add/del.
function paintSplit(highlighter, lang, rows) {
  const oldEls = []
  const newEls = []
  for (const row of rows) {
    const left = row.querySelector('.side.left')
    const right = row.querySelector('.side.right')
    if (left && hasKind(left)) { oldEls.push(left.querySelector('.text')) }
    if (right && hasKind(right)) { newEls.push(right.querySelector('.text')) }
  }
  const oldTokens = tokenize(highlighter, lang, oldEls.map(stripped))
  const newTokens = tokenize(highlighter, lang, newEls.map(stripped))
  if (oldTokens) { oldEls.forEach((el, i) => paint(el, oldTokens[i])) }
  if (newTokens) { newEls.forEach((el, i) => paint(el, newTokens[i])) }
}

function run() {
  // Single-file pages tag <body data-lang>; the multi-file Working Copy page
  // tags each <section class="file" data-lang> with its own language (and
  // leaves unknown-language sections untagged).
  let scopes = [...document.querySelectorAll('section.file[data-lang]')]
    .map((el) => ({ root: el, lang: el.dataset.lang }))
  if (!scopes.length && document.body?.dataset.lang) {
    scopes = [{ root: document.body, lang: document.body.dataset.lang }]
  }
  scopes = scopes.filter((scope) => LANGS[scope.lang])
  if (!scopes.length) { return }
  const grammars = [...new Set(scopes.map((scope) => scope.lang))].map((lang) => LANGS[lang])
  let highlighter
  try {
    highlighter = createHighlighterCoreSync({
      langs: grammars,
      themes: [githubLight, githubDark],
      // forgiving: grammars with untranslatable Oniguruma patterns lose those
      // rules instead of failing the whole file.
      engine: createJavaScriptRegexEngine({ forgiving: true }),
    })
  } catch {
    return
  }
  // Tokens carry the light color inline plus --shiki-dark; this rule flips
  // them in dark mode (!important because it must beat the inline style).
  const style = document.createElement('style')
  style.textContent = '@media (prefers-color-scheme: dark){.text span[style]{color:var(--shiki-dark,currentColor)!important}}'
  document.head.appendChild(style)
  const tasks = []
  for (const scope of scopes) {
    for (const group of groups(scope.root, (el) => el.classList.contains('line'))) {
      tasks.push(() => paintUnified(highlighter, scope.lang, group))
    }
    for (const group of groups(scope.root, (el) => el.classList.contains('row'))) {
      tasks.push(() => paintSplit(highlighter, scope.lang, group))
    }
  }
  // One group per task, yielding in between: the user script runs at
  // documentEnd, before first paint and the height report, so tokenizing
  // everything synchronously would freeze large pages white. Deferring lets
  // the page render first and colors arrive progressively; painting never
  // changes layout, so late tokens can't invalidate the reported height.
  const step = () => {
    const task = tasks.shift()
    if (!task) { highlighter.dispose(); return }
    task()
    setTimeout(step, 0)
  }
  setTimeout(step, 0)
}

run()
