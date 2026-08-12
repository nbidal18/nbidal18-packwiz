package dev.nbidal18.packcompat.autohud;

import static org.junit.jupiter.api.Assertions.assertEquals;

import org.junit.jupiter.api.Test;

class AircraftHudStateTest {
    @Test
    void mountHealthAndThrottleTransitionsAreDistinct() {
        AircraftHudState state = new AircraftHudState();
        Object aircraft = "aircraft-1";

        assertEquals(AircraftHudState.Change.NONE, state.observe(null, Float.NaN, Float.NaN));
        assertEquals(AircraftHudState.Change.MOUNTED, state.observe(aircraft, 20.0f, 0.0f));
        assertEquals(AircraftHudState.Change.NONE, state.observe(aircraft, 20.0f, 0.0f));
        assertEquals(AircraftHudState.Change.ENGINE, state.observe(aircraft, 20.0f, 0.5f));
        assertEquals(AircraftHudState.Change.HEALTH, state.observe(aircraft, 16.0f, 0.5f));
        assertEquals(AircraftHudState.Change.HEALTH_AND_ENGINE, state.observe(aircraft, 12.0f, 1.0f));
        assertEquals(AircraftHudState.Change.NONE, state.observe(null, Float.NaN, Float.NaN));
    }

    @Test
    void changingVehiclesRevealsEvenWhenValuesMatch() {
        AircraftHudState state = new AircraftHudState();
        assertEquals(AircraftHudState.Change.MOUNTED, state.observe("a", 20.0f, 0.0f));
        assertEquals(AircraftHudState.Change.MOUNTED, state.observe("b", 20.0f, 0.0f));
    }
}
