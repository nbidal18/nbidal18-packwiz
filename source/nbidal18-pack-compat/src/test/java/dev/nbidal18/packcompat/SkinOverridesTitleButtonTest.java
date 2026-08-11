package dev.nbidal18.packcompat;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

class SkinOverridesTitleButtonTest {
    @Test
    void splitsTheStandardTitleButtonRowWithoutOverlap() {
        TitleButtonLayout.SplitLayout split = TitleButtonLayout.splitRow(
                100, 200, TitleButtonLayout.DEFAULT_GAP);

        assertEquals(98, split.leftWidth());
        assertEquals(202, split.rightX());
        assertEquals(98, split.rightWidth());
        assertFalse(TitleButtonLayout.overlaps(
                100, 72, split.leftWidth(), 20,
                split.rightX(), 72, split.rightWidth(), 20));
    }

    @Test
    void splitPreservesOddWidthExactly() {
        TitleButtonLayout.SplitLayout split = TitleButtonLayout.splitRow(
                7, 201, TitleButtonLayout.DEFAULT_GAP);

        assertEquals(98, split.leftWidth());
        assertEquals(109, split.rightX());
        assertEquals(99, split.rightWidth());
        assertEquals(201, split.leftWidth() + TitleButtonLayout.DEFAULT_GAP + split.rightWidth());
    }

    @Test
    void refusesAnImpossibleSplit() {
        assertThrows(IllegalArgumentException.class,
                () -> TitleButtonLayout.splitRow(
                        0, TitleButtonLayout.DEFAULT_GAP + 1,
                        TitleButtonLayout.DEFAULT_GAP));
    }

    @Test
    void rectangleCollisionUsesOpenEdges() {
        assertTrue(TitleButtonLayout.overlaps(0, 0, 20, 20, 19, 19, 20, 20));
        assertFalse(TitleButtonLayout.overlaps(0, 0, 20, 20, 20, 0, 20, 20));
        assertFalse(TitleButtonLayout.overlaps(0, 0, 20, 20, 0, 20, 20, 20));
    }
}
