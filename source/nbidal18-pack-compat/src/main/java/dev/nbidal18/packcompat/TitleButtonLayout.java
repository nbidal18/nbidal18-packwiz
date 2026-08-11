package dev.nbidal18.packcompat;

/** Pure layout arithmetic kept independent from client classes for deterministic tests. */
final class TitleButtonLayout {
    static final int DEFAULT_GAP = 4;

    private TitleButtonLayout() {
    }

    static SplitLayout splitRow(int x, int width, int gap) {
        if (gap < 0 || width < gap + 2) {
            throw new IllegalArgumentException("Button row is too narrow to split");
        }
        int leftWidth = (width - gap) / 2;
        int rightWidth = width - gap - leftWidth;
        return new SplitLayout(leftWidth, x + leftWidth + gap, rightWidth);
    }

    static boolean overlaps(
            int firstX,
            int firstY,
            int firstWidth,
            int firstHeight,
            int secondX,
            int secondY,
            int secondWidth,
            int secondHeight
    ) {
        return firstX < secondX + secondWidth
                && firstX + firstWidth > secondX
                && firstY < secondY + secondHeight
                && firstY + firstHeight > secondY;
    }

    record SplitLayout(int leftWidth, int rightX, int rightWidth) {
    }
}
