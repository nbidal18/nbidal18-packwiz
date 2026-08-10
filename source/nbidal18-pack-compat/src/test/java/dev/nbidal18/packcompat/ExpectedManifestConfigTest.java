package dev.nbidal18.packcompat;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

class ExpectedManifestConfigTest {
    @Test
    void acceptsOnlyOneExactLowercaseDigestProperty() {
        String digest = "0123456789abcdef".repeat(4);
        ExpectedManifestConfig parsed = ExpectedManifestConfig.parseForTest(
                "# generated\nexpected-manifest-sha256=" + digest + "\n"
        );
        assertTrue(parsed.valid());
        assertEquals(digest, parsed.sha256());

        assertFalse(ExpectedManifestConfig.parseForTest(
                "expected-manifest-sha256=" + digest.toUpperCase() + "\n").valid());
        assertFalse(ExpectedManifestConfig.parseForTest(
                "expected-manifest-sha256=" + digest + "\nunknown=value\n").valid());
        assertFalse(ExpectedManifestConfig.parseForTest("").valid());
    }
}
