// User guide PDF stylesheet, derived from `zensical2pdf --dump-template`.
//
// A template must export `book`, `admonition` and `fit-image`. Liberation Sans is the
// CI font and shares its metrics with Arial, so local and published layouts match.

#let accent = rgb("#2e7d32")
#let ink = rgb("#1f2328")
#let muted = luma(110)
#let body-font = ("Arial", "Liberation Sans")
#let mono-font = "DejaVu Sans Mono"
#let part-word = (en: "Part", fr: "Partie", de: "Teil", es: "Parte", it: "Parte", pt: "Parte", nl: "Deel")

#let admonition-colors = (
  note: rgb("#448aff"),
  abstract: rgb("#00b0ff"),
  info: rgb("#00b8d4"),
  tip: rgb("#00bfa5"),
  success: rgb("#00c853"),
  question: rgb("#64dd17"),
  warning: rgb("#ff9100"),
  failure: rgb("#ff5252"),
  danger: rgb("#ff1744"),
  bug: rgb("#f50057"),
  example: rgb("#7c4dff"),
  quote: rgb("#9e9e9e"),
  tab: rgb("#3f51b5"),
)

#let admonition(kind, title, body) = {
  let color = admonition-colors.at(kind, default: admonition-colors.note)
  let title = if title == none { upper(kind.first()) + kind.slice(1) } else { title }
  block(
    width: 100%,
    breakable: true,
    radius: 3pt,
    stroke: (left: 3pt + color),
    fill: color.lighten(93%),
    inset: 0pt,
    above: 1.2em,
    below: 1.2em,
    {
      if title != [] {
        block(
          width: 100%,
          inset: (x: 10pt, y: 6pt),
          fill: color.lighten(82%),
          text(weight: "bold", fill: color.darken(35%), title),
        )
      }
      block(width: 100%, inset: (x: 10pt, y: 8pt), body)
    },
  )
}

// The text area of an A4 page is 24.7cm tall; the cap leaves room for a line of text.
#let max-image-height = 23cm

#let fit-image(..args) = layout(size => {
  let natural = measure(image(..args))
  let scale = calc.min(1, size.width / natural.width, max-image-height / natural.height)
  image(..args, width: natural.width * scale)
})

#let book(
  title: "Documentation",
  subtitle: none,
  author: none,
  copyright: none,
  lang: "en",
  parts: false,
  body,
) = {
  let chapter-level = if parts { 2 } else { 1 }
  // Parts stay unnumbered (and don't step the counter), so chapters number continuously.
  let numbers = (..n) => {
    let n = if parts { n.pos().slice(1) } else { n.pos() }
    if n.len() <= 3 { numbering("1.1", ..n) }
  }

  set document(title: title, author: if author == none { () } else { author })
  set page(paper: "a4", margin: (x: 2.2cm, top: 2.5cm, bottom: 2.5cm))
  set text(font: body-font, size: 10.5pt, lang: lang, fill: ink)
  set par(justify: true, leading: 0.68em, spacing: 1em)

  // --- Title page
  page(margin: (x: 2.2cm, top: 6cm, bottom: 3cm), numbering: none)[
    #set par(justify: false)
    #text(size: 34pt, weight: "bold", fill: accent, title)
    #if subtitle != none {
      v(0.6em)
      text(size: 15pt, fill: muted, subtitle)
    }
    #v(2cm)
    #if author != none { text(size: 12pt, author); linebreak() }
    #text(size: 12pt, fill: muted, datetime.today().display("[year]-[month]-[day]"))
    #v(1fr)
    #if copyright != none { text(size: 9pt, fill: muted, copyright) }
  ]

  // --- Table of contents
  set page(numbering: "i")
  counter(page).update(1)
  show outline.entry.where(level: 1): set text(weight: "bold")
  show outline.entry.where(level: 1): set block(above: 1.1em)
  outline(depth: if parts { 3 } else { 2 }, indent: 1.5em)

  // --- Page layout of the body
  set page(
    numbering: "1",
    header: context {
      let page = here().page()
      let openers = query(selector(heading.where(level: 1)).or(heading.where(level: chapter-level)))
      let current = query(heading.where(level: chapter-level)).filter(h => h.location().page() < page)
      if current.len() == 0 or openers.any(h => h.location().page() == page) { return }
      set text(size: 9pt, fill: muted)
      grid(columns: (1fr, auto), emph(title), current.last().body)
      v(-0.6em)
      line(length: 100%, stroke: 0.4pt + luma(200))
    },
  )
  counter(page).update(1)

  // --- Headings
  set heading(numbering: numbers)
  show heading: set text(fill: ink, hyphenate: false)
  show heading: set block(above: 1.5em, below: 0.8em)
  show heading.where(level: chapter-level + 1): set text(size: 15pt)
  show heading.where(level: chapter-level + 2): set text(size: 12.5pt)
  show heading.where(level: chapter-level + 3): set text(size: 11pt, style: "italic")
  show heading.where(level: chapter-level): it => {
    pagebreak(weak: true)
    v(2cm)
    if it.numbering != none {
      text(size: 40pt, weight: "bold", fill: accent, counter(heading).display(it.numbering))
      v(-0.5em)
    }
    text(size: 24pt, weight: "bold", it.body)
    v(1.5em)
  }
  show heading.where(level: 1): set heading(numbering: if parts { none } else { numbers })
  show heading.where(level: 1): it => if not parts { it } else {
    counter("part").step()
    pagebreak(weak: true)
    align(center + horizon)[
      #text(size: 14pt, fill: muted, tracking: 0.15em)[#upper(part-word.at(lang, default: "Part")) #context counter("part").display("I")]
      #v(1em)
      #text(size: 30pt, weight: "bold", fill: accent, it.body)
    ]
    pagebreak()
  }

  // --- Elements
  show raw: set text(font: mono-font, size: 0.88em)
  show raw.where(block: true): it => block(
    width: 100%,
    fill: luma(247),
    stroke: 0.5pt + luma(220),
    inset: 9pt,
    radius: 3pt,
    breakable: true,
    it,
  )
  show raw.where(block: false): box.with(fill: luma(240), inset: (x: 3pt, y: 0pt), outset: (y: 3pt), radius: 2pt)
  show link: set text(fill: accent)
  set table(
    stroke: (x, y) => if y == 0 { (bottom: 0.8pt + ink) } else { (bottom: 0.4pt + luma(210)) },
    inset: (x: 8pt, y: 5pt),
  )
  show table.cell.where(y: 0): strong
  set list(indent: 1em)
  set enum(indent: 1em)

  body
}
