//! Agent replies are Markdown. The core parses them once (CommonMark plus
//! tables, strikethrough and task lists, as the web app's renderer allows) into
//! a flat list of blocks with styled spans, so both shells draw the same
//! structure with their own text system and nothing is parsed twice.
//!
//! Flat on purpose: a nested list is a run of `ListItem`s with a `depth`, and
//! the text of a quote or an item is one span list (paragraphs joined by a
//! line break). That covers what agents write without recursive FFI types.

use pulldown_cmark::{CodeBlockKind, Event, HeadingLevel, Options, Parser, Tag, TagEnd};

/// A run of text with one style.
#[derive(Debug, Clone, Default, PartialEq, uniffi::Record)]
pub struct Span {
    pub text: String,
    pub bold: bool,
    pub italic: bool,
    /// Inline code.
    pub code: bool,
    pub strike: bool,
    /// Where the text links to (links, autolinks and images, which show their alt text).
    pub link: Option<String>,
}

#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum ListMarker {
    Bullet,
    Number {
        value: u64,
    },
    /// A `- [ ]` / `- [x]` item.
    Task {
        done: bool,
    },
    /// A later paragraph of the item above (after a nested list): no marker.
    Continuation,
}

#[derive(Debug, Clone, Default, PartialEq, uniffi::Record)]
pub struct TableRow {
    /// One span list per cell.
    pub cells: Vec<Vec<Span>>,
}

#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum Block {
    Paragraph {
        spans: Vec<Span>,
    },
    /// `level` 1 to 6.
    Heading {
        level: u8,
        spans: Vec<Span>,
    },
    /// `depth` 0 for a top-level item, 1 inside it, ...
    ListItem {
        depth: u32,
        marker: ListMarker,
        spans: Vec<Span>,
    },
    Quote {
        spans: Vec<Span>,
    },
    /// Fenced or indented code, without the trailing newline.
    Code {
        language: Option<String>,
        code: String,
    },
    Table {
        header: TableRow,
        rows: Vec<TableRow>,
    },
    Rule,
}

/// Parses `text` into blocks. Never fails: anything it doesn't model ends up as plain text.
pub fn parse(text: &str) -> Vec<Block> {
    let mut b = Builder::default();
    let options = Options::ENABLE_TABLES | Options::ENABLE_STRIKETHROUGH | Options::ENABLE_TASKLISTS;
    for event in Parser::new_ext(text, options) {
        b.event(event);
    }
    b.flush();
    b.blocks
}

enum Container {
    Quote,
    Item { depth: u32, marker: Option<ListMarker> },
}

#[derive(Default)]
struct Builder {
    blocks: Vec<Block>,
    /// Inline content of the block being built.
    spans: Vec<Span>,
    containers: Vec<Container>,
    /// Next number of each open list; `None` for bullets.
    lists: Vec<Option<u64>>,
    /// A paragraph ended inside a quote or item: the next text starts a new line.
    pending_break: bool,
    bold: u32,
    italic: u32,
    strike: u32,
    links: Vec<String>,
    code: Option<(Option<String>, String)>,
    table: Option<(TableRow, Vec<TableRow>, TableRow)>,
}

impl Builder {
    fn event(&mut self, event: Event) {
        if let Some((_, code)) = &mut self.code {
            match event {
                Event::Text(t) => code.push_str(&t),
                Event::End(TagEnd::CodeBlock) => {
                    let (language, mut code) = self.code.take().unwrap_or_default();
                    while code.ends_with('\n') {
                        code.pop();
                    }
                    self.blocks.push(Block::Code { language, code });
                }
                _ => {}
            }
            return;
        }
        match event {
            Event::Start(tag) => self.start(tag),
            Event::End(tag) => self.end(tag),
            Event::Text(t) => self.text(&t, false),
            Event::Code(t) => self.text(&t, true),
            Event::Html(t) | Event::InlineHtml(t) => self.text(&t, false),
            Event::InlineMath(t) | Event::DisplayMath(t) => self.text(&t, true),
            Event::FootnoteReference(t) => self.text(&format!("[{t}]"), false),
            Event::SoftBreak => self.text(" ", false),
            Event::HardBreak => self.text("\n", false),
            Event::Rule => {
                self.flush();
                self.blocks.push(Block::Rule);
            }
            Event::TaskListMarker(done) => {
                if let Some(Container::Item { marker, .. }) = self.containers.last_mut() {
                    *marker = Some(ListMarker::Task { done });
                }
            }
        }
    }

    fn start(&mut self, tag: Tag) {
        match tag {
            Tag::Paragraph => {}
            Tag::Heading { .. } => self.flush(),
            Tag::BlockQuote(_) => {
                self.flush();
                self.containers.push(Container::Quote);
            }
            Tag::CodeBlock(kind) => {
                self.flush();
                let language = match kind {
                    CodeBlockKind::Fenced(info) => info.split_whitespace().next().filter(|l| !l.is_empty()).map(str::to_owned),
                    CodeBlockKind::Indented => None,
                };
                self.code = Some((language, String::new()));
            }
            Tag::List(start) => {
                self.flush();
                self.lists.push(start);
            }
            Tag::Item => {
                self.flush();
                let depth = self.lists.len().saturating_sub(1) as u32;
                let marker = match self.lists.last_mut() {
                    Some(Some(n)) => {
                        let value = *n;
                        *n += 1;
                        ListMarker::Number { value }
                    }
                    _ => ListMarker::Bullet,
                };
                self.containers.push(Container::Item { depth, marker: Some(marker) });
            }
            Tag::Table(_) => {
                self.flush();
                self.table = Some(Default::default());
            }
            Tag::TableHead | Tag::TableRow | Tag::TableCell => self.spans.clear(),
            Tag::Emphasis => self.italic += 1,
            Tag::Strong => self.bold += 1,
            Tag::Strikethrough => self.strike += 1,
            Tag::Link { dest_url, .. } | Tag::Image { dest_url, .. } => self.links.push(dest_url.to_string()),
            _ => {}
        }
    }

    fn end(&mut self, tag: TagEnd) {
        match tag {
            TagEnd::Paragraph => {
                if self.containers.is_empty() {
                    let spans = std::mem::take(&mut self.spans);
                    if has_text(&spans) {
                        self.blocks.push(Block::Paragraph { spans });
                    }
                } else {
                    self.pending_break = true;
                }
            }
            TagEnd::Heading(level) => {
                let spans = std::mem::take(&mut self.spans);
                self.pending_break = false;
                if has_text(&spans) {
                    self.blocks.push(Block::Heading { level: heading_level(level), spans });
                }
            }
            TagEnd::BlockQuote(_) | TagEnd::Item => {
                self.flush();
                self.containers.pop();
            }
            TagEnd::List(_) => {
                self.lists.pop();
            }
            TagEnd::TableCell => {
                let cell = std::mem::take(&mut self.spans);
                if let Some((_, _, row)) = &mut self.table {
                    row.cells.push(cell);
                }
            }
            TagEnd::TableHead => {
                if let Some((header, _, row)) = &mut self.table {
                    *header = std::mem::take(row);
                }
            }
            TagEnd::TableRow => {
                if let Some((_, rows, row)) = &mut self.table {
                    rows.push(std::mem::take(row));
                }
            }
            TagEnd::Table => {
                if let Some((header, rows, _)) = self.table.take() {
                    self.blocks.push(Block::Table { header, rows });
                }
            }
            TagEnd::Emphasis => self.italic = self.italic.saturating_sub(1),
            TagEnd::Strong => self.bold = self.bold.saturating_sub(1),
            TagEnd::Strikethrough => self.strike = self.strike.saturating_sub(1),
            TagEnd::Link | TagEnd::Image => {
                self.links.pop();
            }
            _ => {}
        }
    }

    fn text(&mut self, text: &str, code: bool) {
        if text.is_empty() {
            return;
        }
        if std::mem::take(&mut self.pending_break) && has_text(&self.spans) {
            self.push_span("\n", false);
        }
        self.push_span(text, code);
    }

    fn push_span(&mut self, text: &str, code: bool) {
        let span = Span {
            text: text.to_owned(),
            bold: self.bold > 0,
            italic: self.italic > 0,
            code,
            strike: self.strike > 0,
            link: self.links.last().cloned(),
        };
        match self.spans.last_mut() {
            Some(last) if same_style(last, &span) => last.text.push_str(text),
            _ => self.spans.push(span),
        }
    }

    /// Ends the text of the innermost quote or item (top-level paragraphs and
    /// headings end on their own events).
    fn flush(&mut self) {
        self.pending_break = false;
        if !has_text(&self.spans) {
            self.spans.clear();
            return;
        }
        let spans = trim(std::mem::take(&mut self.spans));
        match self.containers.last_mut() {
            Some(Container::Quote) => self.blocks.push(Block::Quote { spans }),
            Some(Container::Item { depth, marker }) => {
                let marker = marker.take().unwrap_or(ListMarker::Continuation);
                self.blocks.push(Block::ListItem { depth: *depth, marker, spans });
            }
            None => self.blocks.push(Block::Paragraph { spans }),
        }
    }
}

fn same_style(a: &Span, b: &Span) -> bool {
    a.bold == b.bold && a.italic == b.italic && a.code == b.code && a.strike == b.strike && a.link == b.link
}

fn has_text(spans: &[Span]) -> bool {
    spans.iter().any(|s| !s.text.trim().is_empty())
}

/// Drops the line breaks a container's last paragraph can leave at the end.
fn trim(mut spans: Vec<Span>) -> Vec<Span> {
    while let Some(last) = spans.last_mut() {
        let trimmed = last.text.trim_end_matches('\n').len();
        last.text.truncate(trimmed);
        if last.text.is_empty() {
            spans.pop();
        } else {
            break;
        }
    }
    spans
}

fn heading_level(level: HeadingLevel) -> u8 {
    match level {
        HeadingLevel::H1 => 1,
        HeadingLevel::H2 => 2,
        HeadingLevel::H3 => 3,
        HeadingLevel::H4 => 4,
        HeadingLevel::H5 => 5,
        HeadingLevel::H6 => 6,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn plain(text: &str) -> Span {
        Span { text: text.into(), ..Default::default() }
    }

    #[test]
    fn paragraphs_headings_and_inline_styles() {
        let blocks = parse("# Title\n\nSome **bold** and *it* with `code`,\na [link](https://x.y) and ~~old~~.\n\n---\n");
        assert_eq!(
            blocks,
            vec![
                Block::Heading { level: 1, spans: vec![plain("Title")] },
                Block::Paragraph {
                    spans: vec![
                        plain("Some "),
                        Span { text: "bold".into(), bold: true, ..Default::default() },
                        plain(" and "),
                        Span { text: "it".into(), italic: true, ..Default::default() },
                        plain(" with "),
                        Span { text: "code".into(), code: true, ..Default::default() },
                        plain(", a "),
                        Span { text: "link".into(), link: Some("https://x.y".into()), ..Default::default() },
                        plain(" and "),
                        Span { text: "old".into(), strike: true, ..Default::default() },
                        plain("."),
                    ]
                },
                Block::Rule,
            ]
        );
    }

    #[test]
    fn nested_lists_tasks_and_continuations() {
        let blocks = parse("1. one\n2. two\n   - inner\n   - [x] done\n\n   more of two\n3. three\n");
        let summary: Vec<_> = blocks
            .iter()
            .map(|b| match b {
                Block::ListItem { depth, marker, spans } => {
                    (*depth, marker.clone(), spans.iter().map(|s| s.text.as_str()).collect::<String>())
                }
                other => panic!("unexpected {other:?}"),
            })
            .collect();
        assert_eq!(
            summary,
            vec![
                (0, ListMarker::Number { value: 1 }, "one".into()),
                (0, ListMarker::Number { value: 2 }, "two".into()),
                (1, ListMarker::Bullet, "inner".into()),
                (1, ListMarker::Task { done: true }, "done".into()),
                (0, ListMarker::Continuation, "more of two".into()),
                (0, ListMarker::Number { value: 3 }, "three".into()),
            ]
        );
    }

    #[test]
    fn code_blocks_quotes_and_tables() {
        let blocks = parse(
            "```rust title\nfn main() {}\n```\n\n> quoted\n> line\n>\n> second\n\n| a | b |\n|---|---|\n| 1 | `2` |\n\n    indented\n",
        );
        assert_eq!(blocks[0], Block::Code { language: Some("rust".into()), code: "fn main() {}".into() });
        assert_eq!(blocks[1], Block::Quote { spans: vec![plain("quoted line\nsecond")] });
        assert_eq!(
            blocks[2],
            Block::Table {
                header: TableRow { cells: vec![vec![plain("a")], vec![plain("b")]] },
                rows: vec![TableRow { cells: vec![vec![plain("1")], vec![Span { text: "2".into(), code: true, ..Default::default() }]] }],
            }
        );
        assert_eq!(blocks[3], Block::Code { language: None, code: "indented".into() });
    }

    #[test]
    fn unfinished_markdown_while_streaming() {
        // A reply is parsed again on every refresh, mid-stream too.
        let blocks = parse("Here:\n\n```sh\ncargo te");
        assert_eq!(blocks[1], Block::Code { language: Some("sh".into()), code: "cargo te".into() });
        assert_eq!(parse("**half"), vec![Block::Paragraph { spans: vec![plain("**half")] }]);
        assert!(parse("").is_empty());
        assert!(parse("\n\n  \n").is_empty());
    }
}
