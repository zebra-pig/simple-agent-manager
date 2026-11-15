package org.simpleagentmanager.app

// Agent replies as the core parsed them (markdown.rs): a flat list of blocks
// with styled spans. Drawn with Compose text, so selection, links and font
// scaling work as everywhere else.

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextLinkStyles
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.withLink
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em
import org.simpleagentmanager.core.Block
import org.simpleagentmanager.core.ListMarker
import org.simpleagentmanager.core.Span
import org.simpleagentmanager.core.TableRow

/** The blocks of one reply, top to bottom. */
@Composable
fun MarkdownBlocks(blocks: List<Block>, openUrl: (String) -> Unit, modifier: Modifier = Modifier) {
    Column(modifier) {
        blocks.forEachIndexed { index, block ->
            val previous = blocks.getOrNull(index - 1)
            // Items of one list sit close; everything else gets paragraph spacing.
            val gap = when {
                previous == null -> 0.dp
                previous is Block.ListItem && block is Block.ListItem -> 4.dp
                block is Block.Heading -> 16.dp
                else -> 10.dp
            }
            MarkdownBlock(block, openUrl, Modifier.padding(top = gap))
        }
    }
}

@Composable
private fun MarkdownBlock(block: Block, openUrl: (String) -> Unit, modifier: Modifier) {
    val type = MaterialTheme.typography
    val colors = MaterialTheme.colorScheme
    when (block) {
        is Block.Paragraph -> Text(rememberSpans(block.spans, openUrl), modifier, style = type.bodyLarge)
        is Block.Heading -> Text(
            rememberSpans(block.spans, openUrl),
            modifier,
            style = when (block.level.toInt()) {
                1 -> type.titleLarge
                2 -> type.titleMedium
                else -> type.titleSmall
            },
            fontWeight = FontWeight.SemiBold,
        )
        is Block.ListItem -> Row(modifier.padding(start = 20.dp * block.depth.toInt())) {
            ListMarkerView(block.marker)
            Text(rememberSpans(block.spans, openUrl), Modifier.weight(1f), style = type.bodyLarge)
        }
        is Block.Quote -> Row(modifier.height(IntrinsicSize.Min)) {
            Box(Modifier.width(3.dp).fillMaxHeight().background(colors.outlineVariant, RoundedCornerShape(2.dp)))
            Text(
                rememberSpans(block.spans, openUrl),
                Modifier.padding(start = 12.dp),
                style = type.bodyLarge,
                color = colors.onSurfaceVariant,
            )
        }
        is Block.Code -> CodeBlock(block.code, block.language, modifier)
        is Block.Table -> MarkdownTable(block.header, block.rows, openUrl, modifier)
        Block.Rule -> HorizontalDivider(modifier.padding(vertical = 6.dp), color = colors.outlineVariant)
    }
}

/** The marker column of a list item: wide enough for "10." so the text lines up. */
@Composable
private fun ListMarkerView(marker: ListMarker) {
    val colors = MaterialTheme.colorScheme
    Box(Modifier.width(24.dp), contentAlignment = Alignment.TopStart) {
        when (marker) {
            ListMarker.Bullet -> Text("•", style = MaterialTheme.typography.bodyLarge, color = colors.onSurfaceVariant)
            is ListMarker.Number -> Text("${marker.value}.", style = MaterialTheme.typography.bodyLarge, color = colors.onSurfaceVariant)
            is ListMarker.Task -> Box(
                Modifier.padding(top = 3.dp)
                    .border(1.5.dp, if (marker.done) colors.primary else colors.outline, RoundedCornerShape(4.dp))
                    .background(if (marker.done) colors.primary else Color.Transparent, RoundedCornerShape(4.dp)),
            ) {
                Icon(
                    Icons.Default.Check,
                    contentDescription = null,
                    Modifier.padding(1.dp).width(14.dp).height(14.dp),
                    tint = if (marker.done) colors.onPrimary else Color.Transparent,
                )
            }
            ListMarker.Continuation -> {}
        }
    }
}

@Composable
fun CodeBlock(code: String, language: String?, modifier: Modifier = Modifier) {
    Surface(modifier.fillMaxWidth(), shape = RoundedCornerShape(10.dp), color = MaterialTheme.colorScheme.surfaceContainerHigh) {
        Column(Modifier.padding(vertical = 10.dp)) {
            if (!language.isNullOrBlank()) {
                Text(
                    language,
                    Modifier.padding(horizontal = 12.dp).padding(bottom = 4.dp),
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            // Code keeps its lines: long ones scroll sideways instead of wrapping.
            Text(
                code,
                Modifier.horizontalScroll(rememberScrollState()).padding(horizontal = 12.dp),
                style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace, lineHeight = 1.45.em),
                softWrap = false,
            )
        }
    }
}

/** Columns as wide as their widest cell (up to a limit); wide tables scroll sideways. */
@Composable
private fun MarkdownTable(header: TableRow, rows: List<TableRow>, openUrl: (String) -> Unit, modifier: Modifier) {
    val colors = MaterialTheme.colorScheme
    val style = MaterialTheme.typography.bodyMedium
    val headerStyle = style.copy(fontWeight = FontWeight.SemiBold)
    val measurer = rememberTextMeasurer()
    val density = LocalDensity.current
    val all = listOf(header) + rows
    val columns = all.maxOf { it.cells.size }
    val texts = all.mapIndexed { r, row -> List(columns) { c -> rememberSpans(row.cells.getOrNull(c).orEmpty(), openUrl) to if (r == 0) headerStyle else style } }
    val widths = remember(texts, density, measurer) {
        List(columns) { c ->
            val widest = texts.maxOf { row -> measurer.measure(row[c].first, row[c].second, softWrap = false).size.width }
            with(density) { widest.toDp() }.coerceIn(48.dp, 260.dp) + 24.dp
        }
    }
    Surface(
        modifier.border(1.dp, colors.outlineVariant, RoundedCornerShape(10.dp)),
        shape = RoundedCornerShape(10.dp),
        color = Color.Transparent,
    ) {
        Column(Modifier.horizontalScroll(rememberScrollState())) {
            texts.forEachIndexed { r, row ->
                if (r > 0) HorizontalDivider(Modifier.width(widths.fold(0.dp) { a, b -> a + b }), color = colors.outlineVariant)
                Row(if (r == 0) Modifier.background(colors.surfaceContainerHigh) else Modifier) {
                    row.forEachIndexed { c, (text, cellStyle) ->
                        Text(text, Modifier.width(widths[c]).padding(horizontal = 12.dp, vertical = 8.dp), style = cellStyle)
                    }
                }
            }
        }
    }
}

/** Spans as one styled string; links open through [openUrl]. */
@Composable
fun rememberSpans(spans: List<Span>, openUrl: (String) -> Unit): AnnotatedString {
    val colors = MaterialTheme.colorScheme
    val codeStyle = SpanStyle(fontFamily = FontFamily.Monospace, fontSize = 0.9.em, background = colors.surfaceContainerHighest)
    val linkStyles = TextLinkStyles(SpanStyle(color = colors.primary, textDecoration = TextDecoration.Underline))
    return remember(spans, colors, openUrl) {
        buildAnnotatedString {
            spans.forEach { span ->
                val style = SpanStyle(
                    fontWeight = if (span.bold) FontWeight.SemiBold else null,
                    fontStyle = if (span.italic) FontStyle.Italic else null,
                    textDecoration = if (span.strike) TextDecoration.LineThrough else null,
                ).let { if (span.code) it.merge(codeStyle) else it }
                val link = span.link
                if (link != null) {
                    withLink(LinkAnnotation.Url(link, linkStyles) { openUrl(link) }) { withStyle(style) { append(span.text) } }
                } else {
                    withStyle(style) { append(span.text) }
                }
            }
        }
    }
}

/** Plain text in the body style, for previews of a reply. */
internal val TextStyle.monospace get() = copy(fontFamily = FontFamily.Monospace)
