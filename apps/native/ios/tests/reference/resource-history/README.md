# Native Resources render evidence

The six un-suffixed images are real macOS NSHostingView captures from Xcode
Cloud run 74 (source 653fb31d5). They cover narrow CPU/read/empty/sparse layouts
and wide memory/write layouts. The fixture's data assertions passed. These are
host renders, not iPhone screenshots or pixel-diff baselines.

Native capture limitations are visible in these files: AppKit's cached bitmap
export omits the glass card's vibrant text in dark mode. The two `*-swiftui.png`
exports from run 71 show the same chart content and text via ImageRenderer;
that API instead substitutes a warning placeholder for the native segmented
picker. The chart content did not change between these runs; run 72 only hid
the picker's redundant visual label. The hosting captures show the real picker.

Inspect the two APIs together to review chart marks, axes, spacing, units,
summary values, gaps and picker layout. Neither is a complete dark-mode device
screenshot. Real device chart scrubbing, VoiceOver audio graphs and material
appearance still need interactive verification on Apple hardware.
