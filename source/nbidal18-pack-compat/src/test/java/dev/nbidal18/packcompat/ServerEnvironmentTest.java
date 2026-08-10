package dev.nbidal18.packcompat;

import net.fabricmc.api.EnvType;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

class ServerEnvironmentTest {
    @Test
    void loginQueryEnforcementRunsOnlyOnDedicatedServerEnvironment() {
        assertTrue(Nbidal18PackCompat.shouldEnforceServerLogin(EnvType.SERVER));
        assertFalse(Nbidal18PackCompat.shouldEnforceServerLogin(EnvType.CLIENT));
    }
}
