# Inline HTML tags in Markdown

Shared spec for iOS, Android, and Windows (FEAT-261019-02).

Models often put a little HTML into Markdown, most of all inside table cells,
where Markdown has no line break of its own: `| x<br>y |`, `<b>bold</b>`.
Before this change every renderer showed those tags as text.

All three renderers now support the small whitelist below. **Nothing else.**
This is not an HTML renderer: no HTML parser library, no WebView, no
attributes, no block HTML.

iOS is the reference implementation: `InlineHTMLTags` in
`src/ios/Agent/Markdown/MinisMarkdownParser.swift`. Its test,
`src/ios/MinisTests/Standalone/MarkdownInlineHTMLTagsTests.swift`, runs every
case listed in this spec.

## Whitelist

| Tag (any letter case) | Result | iOS node |
|---|---|---|
| `<br>` `<br/>` `<br />` | line break | `.lineBreak` |
| `<b>…</b>` `<strong>…</strong>` | bold | `.strong` |
| `<i>…</i>` `<em>…</em>` | italic | `.emphasis` |
| `<u>…</u>` | underline | `.htmlStyle(.underline)` |
| `<s>…</s>` `<del>…</del>` `<strike>…</strike>` | strikethrough | `.strikethrough` |
| `<code>…</code>` | inline code | `.code` |
| `<sub>…</sub>` | subscript | `.htmlStyle(.subscript)` |
| `<sup>…</sup>` | superscript | `.htmlStyle(.superscript)` |

Rendering on iOS:
- **Underline:** single underline.
- **Subscript and superscript:** the surrounding font at 75 % of its size. The
  baseline moves −0.15 em for a subscript and +0.35 em for a superscript, where
  1 em is the surrounding font size.
- **Downgrade:** a platform that finds sub/sup expensive may drop the style. It
  must still remove the tags and show only the text between them (`x<sup>2</sup>`
  shows as `x2`). Say so in that platform's report.

## Rules

### 1. Only bare tags count

The whole tag must be `<` + name + `>`. A closing tag adds `/` before the name.

- Whitespace is allowed before `>`: `<br >`, `</b >`.
- For `<br>` only, a `/` is also allowed before `>`: `<br/>`, `<br />`.
- Anything else is **not** whitelisted and is shown as written:
  - attributes: `<b class="x">`, `<span style="…">`;
  - a self-closing style tag: `<b/>`;
  - a closing break: `</br>`;
  - comments: `<!-- … -->`;
  - every tag outside the whitelist: `<div>`, `<span>`, `<a>`, `<img>`,
    `<script>`, `<p>`, `<font>`, and so on.

  Nothing in these tags is parsed or executed.

### 2. Pairing is within one inline run

An opening tag pairs with the next closing tag of the **same name** in the same
sibling list of inline nodes. Nested openers of the same name are counted.

- **Same sibling list** means the run of text, emphasis, links and so on at one
  level of the Markdown inline tree, as cmark produces it. Markdown emphasis
  (`**…**`), a link label, or a table cell each start a new list.
- **Different names never pair:** `<b>` does not close with `</strong>`.
- **The pair wraps everything between it,** including Markdown inlines.
  `<b>**x**</b>` is bold inside bold, and `**a<b>b</b>**` works too.
- **A pair that crosses a Markdown boundary does not match.** In `**x<b>y**</b>`,
  `<b>` is inside the strong and `</b>` is outside it. Both are shown as written.
- **Crossing HTML tags:** the outer pair wins and the inner unmatched tag is
  shown as written. `<b>a<i>b</b>c</i>` shows `a<i>b` in bold, then `c</i>`.

### 3. An unclosed or stray tag is shown as written

`<b>半截` displays exactly `<b>半截`. A `</b>` with no opener displays `</b>`.

This is what a stream shows mid-reply: once `</b>` arrives, the next render
styles the text and drops both tags. Text is never swallowed, and nothing after
an unclosed tag changes.

### 4. `<br>`

- It becomes a line break in body text, list items, headings, and **table
  cells**. A cell with `<br>` is drawn on several lines.
- The newline that often follows `<br>` in the source (`a<br>\nb`) adds no
  leading space to the next line. A soft break directly after a `<br>` is
  dropped.
- A `<br>` alone on its own line, at the start of a paragraph, is an HTML
  *block* in CommonMark (see rule 6). It stays as written.

### 5. Code is literal

- Fenced code blocks and backtick code spans are never touched:
  `` `a<br>b` `` shows `a<br>b`.
- **iOS:** this falls out of cmark, which never emits HTML nodes inside code.
- **A platform that pre-scans text instead of using a parser:** you must skip
  fences and code spans yourself.
- `<code>…</code>` becomes inline code holding the literal text between the
  tags. Whitelisted tags inside it are **not** applied: `<code>a<br>b</code>`
  shows `a<br>b` as code.

### 6. Block HTML is unchanged

A line that CommonMark treats as an HTML block is shown as written, as before.
Examples: `<div>x</div>`, or a line holding only `<br>` or only `<b>` at the
start of a paragraph.

### 7. Copy and export

- **Text copy of what is on screen** (selection copy, "copy all as plain text",
  table copy):
  - `<br>` is a newline;
  - style tags leave no tag text, only their content.

  On iOS this follows from the parsed nodes, through `[InlineNode].plainText`
  and `TableAttachment.plainText()`.
- **Table copy is tab-separated:** a `<br>` in a cell puts a newline inside
  that cell's text, as this spec asks. A spreadsheet will read that newline as
  a new row. See *Open questions*.
- **Image and PDF share:** these render through the same Markdown renderer, so
  they match the screen.
- **"Copy as Markdown" and raw Markdown exports** keep the source text,
  including the tags. That is their purpose.

### 8. One-line previews

Session-list previews, search snippets, notification summaries and every
other "Markdown to plain text" function follow the same whitelist, for one
line of text:

- `<br>` `<br/>` `<br />` become a **space**, not a newline.
- A whitelisted style tag, opening or closing, is removed and its text kept.
  No pairing is needed: a preview has no later render to wait for, so
  `<b>半截` previews as `半截`.
- Everything outside the whitelist stays as written: `<div>`, `<a href>`,
  `<b class=x>`, `<b/>`, a lone `<`.
- **Code is found first and left exactly as it is:** fenced blocks, indented
  code blocks and backtick spans. `` `a<br>b` `` still previews as `a<br>b`.
  A line-by-line regex stripper must find the code ranges before it touches
  any tag, never the other way round.
- **Fast path:** with no `<` (and no `&`, if the function also decodes
  entities) the text is returned untouched. Previews are built for every row
  of the list, so this must cost nothing measurable.

Details settled by the iOS implementation (FEAT-261019-05). Android and
Windows should match them:

- **The closing tag is judged on its own.** `<b class=x>y</b>` previews as
  `<b class=x>y`. The opener has attributes and stays; `</b>` is a whitelisted
  closing tag and goes.
- **`\<` and the three basic entities.** The preview writes `\<` as `<` and
  decodes `&lt;` `&gt;` `&amp;` straight into the output. Other entities stay
  as written, as previews always showed them. `\\<br>` is an escaped
  backslash followed by a real tag, so it previews as `\\` and a space.
- **`<code>…</code>` counts as code** when both tags are on the line: the
  tags go and the text between them is kept as written, as the renderer
  shows it. `x <code>a<br>b</code> y` previews as `x a<br>b y`. An unpaired
  `<code>` is just a dropped tag.
- **Search hit lines.** A hit line that lies inside a fenced or indented code
  block is shown exactly as written. Stripping that one line on its own would
  read its `<br>` as prose.
- **Read-aloud.** `<br>` becomes a newline, which the speech engine turns into
  a pause. Everything else is as for previews. Read-aloud is also fed
  already-rendered text ("read selection"), where a literal `<b>` the user
  wrote via an entity has been decoded. Removing that from speech is harmless:
  a tag has nothing to pronounce.
- **Closed fenced blocks** were already left out of iOS previews as a whole,
  and still are. The text is not changed, only omitted. Unclosed fences and
  `~~~` fences reach the preview, and there the code text is kept as written
  (test case 44).
- iOS: `MarkdownStripper.stripInlineHTMLTags` (`Shared/MarkdownStripper.swift`).
  It is called by `plainText` (preview, notification and search) and by
  `VoiceTextSanitizer`. `MarkdownStripper.isInCodeBlock` is used for search
  hit lines. Tests: `src/ios/MinisTests/Standalone/PlainTextHTMLTagsTests.swift`.

### 9. Showing a tag literally

Three ways to make `<br>` appear as the text `<br>`, the same on screen, in
previews, in copy and in search:

| Write | Shows | Why |
|---|---|---|
| `` `<br>` `` or a fenced block | `<br>` in code | rule 5: code is literal |
| `\<br>` | `<br>` | a backslash makes the `<` a literal character |
| `&lt;br&gt;` | `<br>` | the entity decodes to `<`, and decoded text is never read as a tag |

- **Tag handling works on the source text only.** An entity is decoded into
  output, never back into the text that is scanned for tags. `&lt;b&gt;x`
  shows `<b>x`, never a bold `x`.
- An entity inside code stays as written: `` `&lt;br&gt;` `` shows
  `&lt;br&gt;`.
- **Entities decoded:** cmark (iOS) decodes every HTML5 named entity and all
  numeric ones. A platform with its own parser must decode at least `&lt;`
  `&gt;` `&amp;` `&quot;` `&apos;` `&nbsp;` and numeric `&#60;` / `&#x3C;`.
  Say in its report which others it leaves as written.

## Performance

1. **Fast path.** If the Markdown has no `<` at all, skip the pass entirely.
   - Use a vectorised byte search: `memchr` in C / Swift, the `memchr` crate in
     Rust, `indexOf` on the string in Kotlin.
   - On iOS, `String.utf8.contains` took 0.16 ms on a 60 k-character reply,
     about 3 % of the parse. `memchr` made it unmeasurable.
2. **Only pass over inline lists that contain an HTML node.** Any other list is
   returned as is.
3. **Keep the render cache keys unchanged.** The pass runs at parse time, and
   the parsed tree is what gets cached. On iOS that is `MarkdownContent`,
   stored as `block.cachedMarkdown`.
4. **Report numbers** for long text and a long table, with and without tags,
   against the previous build.

   iOS (macOS host, release build, swift-cmark, median of 9 alternating runs):

   | Input | Before | After | Δ |
   |---|---|---|---|
   | 60 k chars, no `<` | 4.757 ms | 4.808 ms | +1.1 % (noise: −0.4 % in an earlier run) |
   | 400-row table, no `<` | 1.730 ms | 1.735 ms | +0.3 % (noise) |
   | 68 k chars with tags | 5.436 ms | 5.736 ms | +0.30 ms |
   | 400-row table, every row tagged | 2.255 ms | 2.587 ms | +0.33 ms |
   | Stream: 20 re-parses of 4 k-char prefixes | 4.382 ms | 4.542 ms | +0.008 ms per parse |
   | 2000 unclosed `<b>` in one paragraph | — | 2.9 ms total | no quadratic blow-up |

## Test cases

Every platform runs these. "As written" means the visible text equals the
source shown.

| # | Input | Expected |
|---|---|---|
| 1 | `a<br>b` | `a`, line break, `b` |
| 2 | `a<br/>b` | same as 1 |
| 3 | `a<br />b` | same as 1 |
| 4 | `A<BR>b` | `A`, line break, `b` |
| 5 | `\| 列1 \| 列2 \|\n\|---\|---\|\n\| x<br>y \| <b>粗</b> \|` (`\n` = newline) | first body cell `x` / `y` on two lines; second cell bold `粗` |
| 6 | `<b>**双重**</b>` | bold `双重` (bold inside bold) |
| 7 | `<i>斜</i><u>下</u>` | italic `斜`, underlined `下` |
| 8 | `<s>删</s>` | struck `删`; same for `<del>`, `<strike>` |
| 9 | `<strong>a</strong><em>b</em>` | bold `a`, italic `b` |
| 10 | `H<sub>2</sub>O x<sup>2</sup>` | subscript 2, superscript 2 (or plain `H2O x2` when downgraded) |
| 11 | `<code>let x</code>` | inline code `let x` |
| 12 | `` x `a<br>b` y `` | code span `a<br>b`, as written |
| 13 | fenced block containing `a<br><b>b</b>` | block text as written |
| 14 | `<b>半截` | as written |
| 15 | `a < b` | as written |
| 16 | `1 < 2 > 0` | as written |
| 17 | `<div>x</div>` (own line) | as written (HTML block) |
| 18 | `a <div>x</div> b` | as written |
| 19 | `a <span style="color:red">x</span>` | as written |
| 20 | `a <script>x</script>` | as written |
| 21 | `a<br>`+newline+`b` | `a`, line break, `b`; no leading space before `b` |
| 22 | `<B>x</b>` | bold `x` |
| 23 | `<b class="x">y</b>` | as written |
| 24 | `x</b>` | as written |
| 25 | `a</br>b` | as written |
| 26 | `a<b/>b` | as written |
| 27 | `<b>a<i>b</b>c</i>` | bold `a<i>b`, then `c</i>` |
| 28 | `<b>a<b>b</b>c</b>` | bold `a`, bold-in-bold `b`, bold `c` |
| 29 | `**a<b>b</b>**` | bold `a`, bold-in-bold `b` |
| 30 | `<b>a<br>b</b>` | bold `a`, line break, bold `b` |
| 31 | `<code>a<br>b</code>` | inline code `a<br>b` |
| 32 | `[<b>x</b>](https://e.com)` | link whose label is bold `x` |
| 33 | `- a<br>b` | list item on two lines |
| 34 | `# a<b>b</b>` | heading `a` + bold `b` |
| 35 | `x<sup>$n$</sup>` | superscript inline math `n` |
| 36 | `a <!-- c --> b` | as written |
| 37 | **Streaming:** feed a reply one character at a time and render every prefix | no crash; every character received so far is visible, in order |
| 38 | `\<br>` | `<br>` as written, no line break |
| 39 | `&lt;br&gt;` | `<br>` as written, no line break |
| 40 | `&lt;b&gt;x&lt;/b&gt;` | `<b>x</b>` as written, nothing bold |
| 41 | `` `&lt;br&gt;` `` | code span `&lt;br&gt;` |
| 42 | preview of `a<br>b <b>粗</b>` | `a b 粗` |
| 43 | preview of `` x `a<br>b` y `` | `x a<br>b y` (the markers may go, the `<br>` stays) |
| 44 | preview of a fenced block holding `a<br>b` | the block text keeps `a<br>b` |
| 45 | preview of `<b>半截` | `半截` |
| 46 | preview of `<div>x</div>` / `<b class=x>y` | as written |
| 47 | preview of `\<br>` / `&lt;br&gt;` | `<br>` |
| 48 | copy as plain text of a fenced block holding `a<br>b` | `a<br>b`, no newline |
| 49 | preview of `<b class=x>y</b>` | `<b class=x>y` |
| 50 | preview of `a\\<br>b` (escaped backslash) | `a\\ b` |
| 51 | preview of `&lt;b&gt;x&lt;/b&gt;` | `<b>x</b>` (decoded, never stripped) |
| 52 | preview of `&amp;lt;br&amp;gt;` | `&lt;br&gt;` |
| 53 | preview of `a &nbsp; & b` | as written |
| 54 | preview of an indented code block holding `a<br>b` | `a<br>b` kept |
| 55 | search hit inside a fenced block line `x<br>y` | the line as written |
| 56 | read-aloud of `第一行<br>第二行 <b>粗体</b>` | `第一行` newline `第二行 粗体` |
| 57 | read-aloud of `` 看 `a<br>b` `` | `看 a<br>b` |
| 58 | preview of `x <code>a<br>b</code> y` | `x a<br>b y` |

The streaming reply used on iOS:

```
开头<b>粗体</b>中间<br>换行<i>斜<u>下划</u>体</i>尾巴<b>未闭合

| 列 | 值 |
|---|---|
| 甲<br>乙 | <s>删</s> |
```

## Open questions

- **Table copy as TSV.** Following this spec, `<br>` becomes a newline in the
  copied cell, and a spreadsheet will split that row. The alternatives are a
  space, or quoting the cell. The decision is open; iOS ships the newline.
- **Block HTML.** A `<br>` alone on its own line, or a paragraph that starts
  with an HTML block line, stays literal. Handling it would mean interpreting
  block HTML, which this spec rules out.
- **`<code>` with Markdown inside.** cmark parses Markdown between `<code>` and
  `</code>` before this pass runs, so `<code>**x**</code>` becomes code `x` and
  the asterisks are lost. Backtick code is unaffected.
